#!/usr/bin/env bats
# Tests for pingstat. Uses the fake ping/curl/wget in tests/bin and a real sqlite3.

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export NET_LOG="$BATS_TEST_TMPDIR/net.log"
    export NET_STUB_FILE="$BATS_TEST_TMPDIR/served"
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

# An empty database for a server in the config
new_db() {
    servers "$1"
    "$PINGSTAT" -d > /dev/null
}

# run_at <server> <minutes ago> <loss|NULL> [status]: a run with or without a reply
run_at() {
    query "$1" "INSERT INTO ping_data(timestamp, avg, loss, status) VALUES (datetime('now', '-$2 minutes'), 1, $3, NULLIF('${4:-}', ''));"
}

# An installed pingstat for the --update and install tests
installed() {
    INSTALLED="$HOME/bin/pingstat"
    mkdir -p "$HOME/bin"
    echo '#!/usr/bin/env bash' > "$INSTALLED"
    echo 'VERSION="0.0.1"' >> "$INSTALLED"
    chmod +x "$INSTALLED"
    OLD_CONTENT=$(cat "$INSTALLED")
}

# A directory to use as PATH that has wget but no curl
path_without_curl() {
    local dir="$BATS_TEST_TMPDIR/nocurl" tool
    mkdir -p "$dir"
    cp "$BATS_TEST_DIRNAME/bin/ping" "$BATS_TEST_DIRNAME/bin/wget" "$dir"
    for tool in bash env sqlite3 awk realpath dirname basename mktemp rm chmod mv grep head; do
        ln -s "$(command -v "$tool")" "$dir/$tool"
    done
    echo "$dir"
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

@test "without a terminal, -s with an unknown server fails instead of adding it" {
    servers ok.test
    run "$PINGSTAT" -p -s typo.test < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"Server 'typo.test' is not in your config."* ]]
    [[ "$output" == *"Add it with 'pingstat add typo.test'."* ]]
    [ "$(cat "$XDG_CONFIG_HOME/pingstat/servers.list")" = "ok.test" ]
    [ ! -e "$DATA/typo.test.db" ]
}

@test "without a terminal, add of a server that does not answer fails" {
    run "$PINGSTAT" add down.test < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"Not added. Run 'pingstat add down.test' in a terminal"* ]]
    run "$PINGSTAT" list
    [[ "$output" == *"No servers in config."* ]]
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

@test "-p records a server that does not answer as 100% loss" {
    servers down.test
    run "$PINGSTAT" -p
    [ "$status" -eq 0 ]
    [ "$(query down.test 'SELECT min IS NULL, loss, status FROM ping_data;')" = "1|100.0|ok" ]
}

@test "-p records DNS and network errors as such, not as lost packets" {
    servers nodns.test noroute.test
    run "$PINGSTAT" -p
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pinged nodns.test -> no result (dns_error)"* ]]
    [[ "$output" == *"Pinged noroute.test -> no result (net_error)"* ]]
    [ "$(query nodns.test 'SELECT loss IS NULL, status FROM ping_data;')" = "1|dns_error" ]
    [ "$(query noroute.test 'SELECT loss IS NULL, status FROM ping_data;')" = "1|net_error" ]
}

@test "-p fails on ping output it does not recognise and records no loss" {
    servers weird.test ok.test
    run "$PINGSTAT" -p
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: Could not measure weird.test -> unexpected ping output: some ping output"* ]]
    [[ "$output" == *"ERROR: Run for weird.test failed."* ]]
    [ "$(query weird.test 'SELECT loss IS NULL, status FROM ping_data;')" = "1|error" ]
    [ "$(query ok.test 'SELECT COUNT(*) FROM ping_data;')" = "1" ]
}

@test "-p fails when a result cannot be stored, and still stores the others" {
    servers broken.test readonly.test ok.test
    mkdir -p "$DATA"
    echo "this is not a database, and long enough for sqlite to notice that it is not" > "$DATA/broken.test.db"
    "$PINGSTAT" -p -s readonly.test
    chmod 444 "$DATA/readonly.test.db"

    run "$PINGSTAT" -p
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: Run for broken.test failed."* ]]
    [[ "$output" == *"ERROR: Run for readonly.test failed."* ]]
    [[ "$output" != *"Pinged broken.test"* ]]
    [[ "$output" != *"Pinged readonly.test"* ]]
    [[ "$output" == *"Pinged ok.test "* ]]
    [ "$(query ok.test 'SELECT COUNT(*) FROM ping_data;')" = "1" ]
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
    run "$PINGSTAT" -d 36500 -s ok.test
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

@test "-d and -m show only the last N calendar days and months, not N periods with data" {
    servers ok.test
    "$PINGSTAT" -p
    insert ok.test "datetime('now', '-3 days'), 1, 2, 3, 0.5, 0"
    insert ok.test "datetime('now', '-100 days'), 1, 2, 3, 0.5, 0"
    insert ok.test "datetime('now', 'start of month', '-14 months'), 1, 2, 3, 0.5, 0"

    run "$PINGSTAT" -d 7 -s ok.test
    [ "$(echo "$output" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} ')" -eq 2 ]
    run "$PINGSTAT" -d 3 -s ok.test
    [ "$(echo "$output" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} ')" -eq 1 ]
    run "$PINGSTAT" -d 0 -s ok.test
    [ "$(echo "$output" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} ')" -eq 0 ]

    run "$PINGSTAT" -m 12 -s ok.test
    [[ "$output" != *"$(date -d "$(date +%Y-%m-15) -14 months" +%Y-%m)"* ]]
    run "$PINGSTAT" -m 20 -s ok.test
    [[ "$output" == *"$(date -d "$(date +%Y-%m-15) -14 months" +%Y-%m)"* ]]
}

@test "-d keeps failed runs out of avg_loss and counts them" {
    servers ok.test
    "$PINGSTAT" -p
    run_at ok.test 0 NULL dns_error
    run_at ok.test 0 NULL error
    run "$PINGSTAT" -d -s ok.test
    [[ "$output" =~ failed\ +weekday ]]
    [[ "$output" =~ \ 25\.0%\ +2\ +[A-Z] ]]

    # Nothing measured at all: no loss figure instead of 0%
    new_db nodns.test
    "$PINGSTAT" -p
    run "$PINGSTAT" -d -s nodns.test
    [[ "$output" =~ -\ +1\ +[A-Z] ]]
    [[ "$output" != *"0.0%"* ]]
}

@test "existing databases get the status column once and keep their rows" {
    servers ok.test
    mkdir -p "$DATA"
    sqlite3 "$DATA/ok.test.db" "CREATE TABLE ping_data (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP, min REAL, avg REAL, max REAL, mdev REAL, loss REAL);"
    sqlite3 "$DATA/ok.test.db" "INSERT INTO ping_data(loss) VALUES (100);"
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    [ "$(query ok.test 'SELECT loss, status IS NULL FROM ping_data ORDER BY id LIMIT 1;')" = "100.0|1" ]
    [ "$(query ok.test "SELECT COUNT(*) FROM ping_data WHERE status = 'ok';")" = "2" ]
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

@test "-o keeps the real start of an outage that began before the window" {
    new_db ok.test
    local m
    run_at ok.test 7300 0
    for ((m = 7290; m >= 10; m -= 10)); do run_at ok.test "$m" 100; done
    run_at ok.test 0 0
    run "$PINGSTAT" -o 3 -s ok.test
    [ "$(echo "$output" | grep -cE '^[0-9]{4}-')" -eq 1 ]
    [[ "$output" =~ $(date -d '-7290 minutes' '+%Y-%m-%d %H:%M').{4}\ +$(date '+%Y-%m-%d').{9}\ +121h\ 30m\ +729\ +no\ reply ]]
}

@test "-o does not show an outage that ended before the window" {
    new_db ok.test
    run_at ok.test 7300 0
    run_at ok.test 7290 100
    run_at ok.test 7280 0
    run_at ok.test 7270 0
    run_at ok.test 0 0
    run "$PINGSTAT" -o 3 -s ok.test
    [[ "$output" == *"No outages."* ]]
}

@test "-o does not count a stopped monitor as an ongoing outage" {
    new_db ok.test
    local m
    for m in 5040 5030 5020 5010; do run_at ok.test "$m" 0; done
    run_at ok.test 5000 100
    run_at ok.test 4990 100
    run "$PINGSTAT" -o -s ok.test
    [[ "$output" =~ monitoring\ gap\ +0h\ 10m\ +2 ]]
    [[ "$output" != *"ongoing"* ]]
}

@test "-o ends an outage at a monitoring gap inside it" {
    new_db ok.test
    local m
    for m in 5040 5030 5020 5010; do run_at ok.test "$m" 0; done
    run_at ok.test 5000 100
    run_at ok.test 60 100
    run_at ok.test 50 0
    run_at ok.test 40 0
    run "$PINGSTAT" -o -s ok.test
    [ "$(echo "$output" | grep -cE '^[0-9]{4}-')" -eq 2 ]
    # Newest first: a 10-minute outage, then the one the monitor lost track of
    [[ "$output" =~ $(date -d '-50 minutes' '+%Y-%m-%d %H:%M').{4}\ +0h\ 10m\ +1 ]]
    [[ "$output" =~ monitoring\ gap\ +0h\ 00m\ +1 ]]
}

@test "-o names the cause, and failed measurements are not outages" {
    new_db ok.test
    run_at ok.test 100 0
    run_at ok.test 90 NULL dns_error
    run_at ok.test 80 NULL dns_error
    run_at ok.test 70 0
    run_at ok.test 60 NULL net_error
    run_at ok.test 50 0
    run_at ok.test 40 NULL dns_error
    run_at ok.test 30 100
    run_at ok.test 20 0
    run_at ok.test 10 NULL error
    run_at ok.test 0 0
    run "$PINGSTAT" -o -s ok.test
    [ "$(echo "$output" | grep -cE '^[0-9]{4}-')" -eq 3 ]
    [[ "$output" =~ 0h\ 20m\ +2\ +dns ]]
    [[ "$output" =~ 0h\ 10m\ +1\ +network ]]
    [[ "$output" =~ 0h\ 20m\ +2\ +mixed ]]
}

@test "databases get a timestamp index, also existing ones" {
    servers ok.test
    mkdir -p "$DATA"
    sqlite3 "$DATA/ok.test.db" "CREATE TABLE ping_data (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP, min REAL, avg REAL, max REAL, mdev REAL, loss REAL);"
    "$PINGSTAT" -d > /dev/null
    [ "$(query ok.test "SELECT name FROM sqlite_master WHERE type = 'index';")" = "ping_data_timestamp" ]
}

@test "-o says so when there were no outages" {
    servers ok.test
    "$PINGSTAT" -p
    run "$PINGSTAT" -o
    [ "$status" -eq 0 ]
    [[ "$output" == *"No outages."* ]]
}

# --- Installing and updating ---

@test "install replaces the script with the download" {
    installed
    cp "$PINGSTAT" "$NET_STUB_FILE"
    PATH="$HOME/bin:$PATH" run bash "$BATS_TEST_DIRNAME/../install" < /dev/null
    [ "$status" -eq 0 ]
    cmp "$NET_STUB_FILE" "$INSTALLED"
    [ -x "$INSTALLED" ]
    [ "$(ls -A "$HOME/bin")" = "pingstat" ]
}

@test "an interrupted install keeps the installed script" {
    installed
    cp "$PINGSTAT" "$NET_STUB_FILE"
    NET_STUB_LINES=30 PATH="$HOME/bin:$PATH" run bash "$BATS_TEST_DIRNAME/../install" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to download"* ]]
    [ "$(cat "$INSTALLED")" = "$OLD_CONTENT" ]
    [ "$(ls -A "$HOME/bin")" = "pingstat" ]
}

@test "install refuses a download that is not pingstat" {
    installed
    echo "<html>Not Found</html>" > "$NET_STUB_FILE"
    PATH="$HOME/bin:$PATH" run bash "$BATS_TEST_DIRNAME/../install" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a valid pingstat script"* ]]
    [ "$(cat "$INSTALLED")" = "$OLD_CONTENT" ]
    [ "$(ls -A "$HOME/bin")" = "pingstat" ]
}

@test "a failed install with wget keeps the installed script" {
    installed
    PATH="$HOME/bin:$(path_without_curl)" run bash "$BATS_TEST_DIRNAME/../install" < /dev/null
    [ "$status" -eq 1 ]
    [ "$(cat "$INSTALLED")" = "$OLD_CONTENT" ]
    [ "$(ls -A "$HOME/bin")" = "pingstat" ]
}

@test "--update replaces the script with the download" {
    installed
    cp "$PINGSTAT" "$INSTALLED"
    sed 's/^VERSION=.*/VERSION="9.9.9"/' "$PINGSTAT" > "$NET_STUB_FILE"
    run "$INSTALLED" --update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Update complete! Running version: 9.9.9"* ]]
    cmp "$NET_STUB_FILE" "$INSTALLED"
    [ -x "$INSTALLED" ]
    [ "$(ls -A "$HOME/bin")" = "pingstat" ]
}

@test "--update keeps the script when the download is cut off or invalid" {
    installed
    cp "$PINGSTAT" "$INSTALLED"
    local before
    before=$(cat "$INSTALLED")
    sed 's/^VERSION=.*/VERSION="9.9.9"/' "$PINGSTAT" > "$NET_STUB_FILE"

    NET_STUB_LINES=30 run "$INSTALLED" --update
    [ "$status" -eq 1 ]
    [[ "$output" == *"Download failed. Nothing was changed."* ]]
    [ "$(cat "$INSTALLED")" = "$before" ]

    # VERSION is there, but the file ends in the middle of a function
    sed -i '46,$d' "$NET_STUB_FILE"
    run "$INSTALLED" --force-update
    [ "$status" -eq 1 ]
    [[ "$output" == *"not appear to be a valid pingstat script"* ]]
    [ "$(cat "$INSTALLED")" = "$before" ]
    [ "$(ls -A "$HOME/bin")" = "pingstat" ]
}
