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
    printf '%s\n' "$@" > "$XDG_CONFIG_HOME/pingstat/servers.list"
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

@test "add rejects names that are not host names or IP addresses" {
    for name in -c1 ../evil a/b ".hidden" "a b"; do
        run "$PINGSTAT" add "$name"
        [ "$status" -eq 1 ]
        [[ "$output" == "Invalid server name '$name'."* ]]
    done
    run "$PINGSTAT" add 2001:db8::1
    [ "$status" -eq 0 ]
}

@test "servers.list ignores comments, blank lines and invalid names" {
    printf '%s\n' "# my servers" "" "  ok.test   # router" "-bad" "two.test" > "$XDG_CONFIG_HOME/pingstat/servers.list"
    run "$PINGSTAT" list
    [[ "$output" == *"Ignoring invalid server name '-bad'"* ]]
    [[ "$output" == *"ok.test => "* ]]
    [[ "$output" == *"two.test => "* ]]
}

@test "servers.conf from before 1.4.0 is migrated without being executed" {
    local conf="$XDG_CONFIG_HOME/pingstat/servers.conf"
    echo 'SERVERS="ok.test two.test"' > "$conf"
    echo "touch '$BATS_TEST_TMPDIR/executed'" >> "$conf"
    run "$PINGSTAT" list
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "Migrated "* ]]
    [[ "$output" == *"ok.test => "* ]]
    [[ "$output" == *"two.test => "* ]]
    [ ! -e "$BATS_TEST_TMPDIR/executed" ]
    [ ! -e "$conf" ]
    [ -e "$conf.bak" ]
    [ "$(grep -v '^#' "$XDG_CONFIG_HOME/pingstat/servers.list")" = "$(printf 'ok.test\ntwo.test')" ]

    # Only once
    run "$PINGSTAT" list
    [[ "$output" != *"Migrated"* ]]
}

@test "--uninstall asks first and keeps everything unless confirmed" {
    local copy="$BATS_TEST_TMPDIR/bin/pingstat"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cp "$PINGSTAT" "$copy"
    servers ok.test
    "$copy" -p

    run "$copy" --uninstall < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"Uninstall cancelled."* ]]
    run bash -c "echo n | '$copy' --uninstall"
    [ "$status" -eq 1 ]
    [ -e "$copy" ] && [ -e "$DATA/ok.test.db" ] && [ -e "$XDG_CONFIG_HOME/pingstat/servers.list" ]

    run bash -c "echo y | '$copy' --uninstall"
    [ "$status" -eq 0 ]
    [ ! -e "$copy" ] && [ ! -e "$DATA" ] && [ ! -e "$XDG_CONFIG_HOME/pingstat" ]
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

@test "-p, -d, -m, -H, -o and list make no network calls" {
    servers ok.test
    "$PINGSTAT" -p
    "$PINGSTAT" -d
    "$PINGSTAT" -m
    "$PINGSTAT" -H
    "$PINGSTAT" -o
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

@test "-o lists outages with start, recovery and duration" {
    servers ok.test
    mkdir -p "$DATA"
    "$PINGSTAT" -d -s ok.test > /dev/null   # creates the database
    insert ok.test "datetime('now', '-70 minutes'), 1, 2, 3, 0.5, 0"
    insert ok.test "datetime('now', '-60 minutes'), NULL, NULL, NULL, NULL, 100"
    insert ok.test "datetime('now', '-55 minutes'), NULL, NULL, NULL, NULL, 100"
    insert ok.test "datetime('now', '-50 minutes'), NULL, NULL, NULL, NULL, 100"
    insert ok.test "datetime('now', '-40 minutes'), 1, 2, 3, 0.5, 25"
    insert ok.test "datetime('now', '-5 minutes'), NULL, NULL, NULL, NULL, 100"
    # Outside the default 30-day window
    insert ok.test "datetime('now', '-40 days'), NULL, NULL, NULL, NULL, 100"

    run "$PINGSTAT" -o -s ok.test
    [ "$status" -eq 0 ]
    [[ "$output" == *"Outages for 'ok.test' (last 30 days)"* ]]
    [ "$(echo "$output" | grep -cE '^[0-9]{4}-')" -eq 2 ]
    # Newest first: the ongoing one, then the 20-minute one with 3 failed runs
    [[ "$output" =~ ongoing\ +0h\ 0[45]m\ +1 ]]
    [[ "$output" =~ $(date -d '-60 minutes' '+%Y-%m-%d %H:%M').{4}\ +$(date -d '-40 minutes' '+%Y-%m-%d %H:%M').{4}\ +0h\ 20m\ +3 ]]

    run "$PINGSTAT" -o 60 -s ok.test
    [ "$(echo "$output" | grep -cE '^[0-9]{4}-')" -eq 3 ]
}

@test "-o says so when there were no outages" {
    servers ok.test
    "$PINGSTAT" -p
    run "$PINGSTAT" -o
    [ "$status" -eq 0 ]
    [[ "$output" == *"No outages."* ]]
}
