#!/usr/bin/env bats
# Tests for pingstat. Uses the fake ping/curl/wget in tests/bin and a real sqlite3.

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export NET_LOG="$BATS_TEST_TMPDIR/net.log"
    export TZ="Europe/Zagreb"
    PINGSTAT="$BATS_TEST_DIRNAME/../pingstat"
    DATA="$XDG_DATA_HOME/pingstat"
    mkdir -p "$XDG_CONFIG_HOME/pingstat"
}

servers() {
    echo "SERVERS=\"$*\"" > "$XDG_CONFIG_HOME/pingstat/servers.conf"
}

query() {
    sqlite3 "$DATA/$1.db" "$2"
}

insert() {
    query "$1" "INSERT INTO ping_data(timestamp, min, avg, max, mdev, loss) VALUES ($2);"
}

# --- Server management ---

@test "add, list and remove a server" {
    run "$PINGSTAT" add ok.test
    [ "$status" -eq 0 ]
    [[ "$output" == *"Added server 'ok.test'"* ]]

    run "$PINGSTAT" list
    [[ "$output" == *"ok.test => $DATA/ok.test.db"* ]]

    run "$PINGSTAT" remove ok.test
    [[ "$output" == *"Removed server 'ok.test'"* ]]
    run "$PINGSTAT" list
    [[ "$output" == *"No servers in config."* ]]
}

@test "add and -s without an argument print usage" {
    run "$PINGSTAT" add
    [ "$status" -eq 1 ]
    [[ "$output" == "Usage: pingstat add <server>" ]]

    run "$PINGSTAT" -d -s
    [ "$status" -eq 1 ]
    [[ "$output" == "Usage: -s <server>" ]]
}

# --- Pinging ---

@test "-p records iputils output" {
    servers ok.test
    run "$PINGSTAT" -p
    [ "$status" -eq 0 ]
    [ "$(query ok.test 'SELECT min, avg, max, mdev, loss FROM ping_data;')" = "10.1|12.5|15.0|1.2|25.0" ]
}

@test "-p records BusyBox and BSD output" {
    servers a.busybox b.bsd
    run "$PINGSTAT" -p
    [ "$status" -eq 0 ]
    [ "$(query a.busybox 'SELECT min, avg, max, mdev IS NULL, loss FROM ping_data;')" = "20.1|22.5|25.0|1|0.0" ]
    [ "$(query b.bsd 'SELECT min, avg, max, mdev, loss FROM ping_data;')" = "30.1|32.5|35.0|2.4|50.0" ]
}

@test "-p records unreachable and unresolvable servers as 100% loss" {
    servers down.test nodns.test
    run "$PINGSTAT" -p
    [ "$status" -eq 0 ]
    [ "$(query down.test 'SELECT min IS NULL, loss FROM ping_data;')" = "1|100.0" ]
    [ "$(query nodns.test 'SELECT min IS NULL, loss FROM ping_data;')" = "1|100.0" ]
}

@test "-p pings servers in parallel and prints results in config order" {
    servers one.test two.test three.test four.test
    export PING_STUB_SLEEP=1
    SECONDS=0
    run "$PINGSTAT" -p
    [ "$status" -eq 0 ]
    [ "$SECONDS" -lt 3 ]
    [[ "${lines[0]}" == "Pinged one.test "* ]]
    [[ "${lines[1]}" == "Pinged two.test "* ]]
    [[ "${lines[2]}" == "Pinged three.test "* ]]
    [[ "${lines[3]}" == "Pinged four.test "* ]]
}

@test "-p skips a server whose previous ping is still running" {
    command -v flock >/dev/null || skip "flock not installed"
    servers ok.test other.test
    mkdir -p "$DATA"
    exec 8>"$DATA/ok.test.lock"
    flock -n 8
    run "$PINGSTAT" -p
    exec 8>&-
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "Skipped ok.test -> previous ping still running" ]]
    [[ "${lines[1]}" == "Pinged other.test "* ]]
}

@test "-p, -d, -m, -H and list make no network calls" {
    servers ok.test
    "$PINGSTAT" -p
    "$PINGSTAT" -d
    "$PINGSTAT" -m
    "$PINGSTAT" -H
    "$PINGSTAT" list
    [ ! -e "$NET_LOG" ]
}

@test "--version warns instead of reporting a new version when offline" {
    run "$PINGSTAT" --version
    [[ "$output" == *"Current version:"* ]]
    [[ "$output" == *"Unable to determine the latest available version"* ]]
    [[ "$output" != *"New version available"* ]]
}

# --- Stats ---

@test "-d groups by local day and shows jitter" {
    servers ok.test
    "$PINGSTAT" -p -s ok.test
    # 23:30 UTC on Oct 20 is 01:30 on Oct 21 in Zagreb
    insert ok.test "'2026-10-20 23:30:00', 1, 2, 3, 0.5, 0"
    run "$PINGSTAT" -d -s ok.test
    [ "$status" -eq 0 ]
    [[ "$output" == *"avg_jitter"* ]]
    [[ "$output" == *"2026-10-21"* ]]
    [[ "$output" == *"Wednesday"* ]]
    [[ "$output" != *"2026-10-20"* ]]
}

@test "-d and -m show '-' for latency when no ping got a reply" {
    servers down.test
    "$PINGSTAT" -p
    run "$PINGSTAT" -d -s down.test
    [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}\ +-\ +-\ +-\ +-\ +-\ +-\ +100\.0% ]]
    run "$PINGSTAT" -m -s down.test
    [[ "$output" =~ [0-9]{4}-[0-9]{2}\ +-\ +-\ +-\ +-\ +-\ +-\ +100\.0% ]]
}

@test "-H groups by local hour over the last N days" {
    servers ok.test
    "$PINGSTAT" -p
    insert ok.test "datetime('now', '-10 days'), 1, 2, 3, 0.5, 0"
    run "$PINGSTAT" -H 3 -s ok.test
    [ "$status" -eq 0 ]
    [[ "$output" == *"Hourly profile for 'ok.test' (last 3 days)"* ]]
    [[ "$output" =~ $(date +%H):00\ +10\.100 ]]
    # The row from 10 days ago is outside the window
    [ "$(echo "$output" | grep -cE '^[0-9]{2}:00 ')" -eq 1 ]
}
