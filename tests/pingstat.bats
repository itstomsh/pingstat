#!/usr/bin/env bats
# Tests for pingstat. Uses the fake ping/curl/wget in tests/bin and a real sqlite3.

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export NET_LOG="$BATS_TEST_TMPDIR/net.log"
    export NET_STUB_FILE="$BATS_TEST_TMPDIR/served"
    export NET_STUB_TAGS="$BATS_TEST_TMPDIR/tags"
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

# Local time of the nth run (from 0) of a server, to the minute; from the database,
# as the clock may have passed a minute since the run was stored
run_minute() {
    query "$1" "SELECT strftime('%Y-%m-%d %H:%M', timestamp, 'localtime') FROM ping_data ORDER BY id LIMIT 1 OFFSET $2;"
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

# release_tags <tag>...: the tags GitHub reports, in its own order
release_tags() {
    local tag
    for tag in "$@"; do
        printf '  {\n    "name": "%s",\n    "commit": {}\n  },\n' "$tag"
    done > "$NET_STUB_TAGS"
}

# An installed pingstat for the --update and install tests
installed() {
    release_tags 9.9.9 1.0.0
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
    for tool in bash env sqlite3 awk dirname basename mktemp rm chmod mv grep head sort tail; do
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
    [[ "$output" == *"$DATA/ok.test.db"* ]]

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

@test "the last server can be removed, and then one added again" {
    servers ok.test
    run "$PINGSTAT" remove ok.test
    [ "$status" -eq 0 ]
    run "$PINGSTAT" add other.test
    [ "$status" -eq 0 ]
    [ "$(grep -v '^#' "$XDG_CONFIG_HOME/pingstat/servers.list")" = "other.test" ]
}

@test "writing the server list leaves no other files and keeps it readable" {
    run "$PINGSTAT" add ok.test
    [ "$status" -eq 0 ]
    [ -z "$(find "$XDG_CONFIG_HOME/pingstat" -name 'servers.list.*')" ]
    [ "$(wc -l < "$XDG_CONFIG_HOME/pingstat/servers.list")" -eq 2 ]
    [ -n "$(find "$XDG_CONFIG_HOME/pingstat/servers.list" -perm 644)" ]
}

@test "a symlinked server list stays a symlink" {
    local real="$BATS_TEST_TMPDIR/dotfiles/servers.list"
    mkdir -p "$(dirname "$real")"
    echo "ok.test" > "$real"
    ln -s "$real" "$XDG_CONFIG_HOME/pingstat/servers.list"
    run "$PINGSTAT" add two.test
    [ "$status" -eq 0 ]
    [ -L "$XDG_CONFIG_HOME/pingstat/servers.list" ]
    [ "$(grep -v '^#' "$real")" = "$(printf 'ok.test\ntwo.test')" ]
}

@test "servers.list ignores comments, blank lines and invalid names" {
    printf '%s\n' "# my servers" "" "  ok.test   # router" "-bad" "two.test" > "$XDG_CONFIG_HOME/pingstat/servers.list"
    run "$PINGSTAT" list
    [[ "$output" == *"Ignoring invalid server name '-bad'"* ]]
    [[ "$output" == *"ok.test "* ]]
    [[ "$output" == *"two.test "* ]]
}

@test "servers.conf from before 1.4.0 is migrated without being executed" {
    local conf="$XDG_CONFIG_HOME/pingstat/servers.conf"
    echo 'SERVERS="ok.test two.test"' > "$conf"
    echo "touch '$BATS_TEST_TMPDIR/executed'" >> "$conf"
    run "$PINGSTAT" list
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "Migrated "* ]]
    [[ "$output" == *"ok.test "* ]]
    [[ "$output" == *"two.test "* ]]
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

@test "unknown arguments fail before anything runs" {
    servers ok.test other.test
    local args
    for args in "-p -S ok.test" "-p extra" "-d --not-a-real-option" "-d 7x" "-m 1 2" "-o x" "-H x" "-p -s ok.test extra"; do
        # shellcheck disable=SC2086
        run "$PINGSTAT" $args
        [ "$status" -eq 1 ]
        [[ "$output" == "Unknown argument "* ]]
    done
    [ ! -e "$DATA/ok.test.db" ]

    run "$PINGSTAT" list extra
    [ "$status" -eq 1 ]
    [[ "$output" == "Unknown argument 'extra'."* ]]
    run "$PINGSTAT" add new.test extra
    [ "$status" -eq 1 ]
    run "$PINGSTAT" remove ok.test other.test
    [ "$status" -eq 1 ]
    [ "$(cat "$XDG_CONFIG_HOME/pingstat/servers.list")" = "$(printf 'ok.test\nother.test')" ]
}

@test "--uninstall with an extra argument removes nothing" {
    local copy="$BATS_TEST_TMPDIR/bin/pingstat"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cp "$PINGSTAT" "$copy"
    run bash -c "echo y | '$copy' --uninstall typo"
    [ "$status" -eq 1 ]
    [ -e "$copy" ]
}

@test "add and remove at the same time lose no changes" {
    command -v flock >/dev/null || skip "flock not installed"
    local s
    for s in a b c d; do PING_STUB_SLEEP=1 "$PINGSTAT" add "$s.test" > /dev/null & done
    wait
    [ "$(grep -cv '^#' "$XDG_CONFIG_HOME/pingstat/servers.list")" -eq 4 ]

    for s in a b c; do "$PINGSTAT" remove "$s.test" > /dev/null & done
    wait
    [ "$(grep -v '^#' "$XDG_CONFIG_HOME/pingstat/servers.list")" = "d.test" ]
}

@test "the same server added twice at the same time is listed once" {
    command -v flock >/dev/null || skip "flock not installed"
    PING_STUB_SLEEP=1 "$PINGSTAT" add ok.test > /dev/null &
    PING_STUB_SLEEP=1 "$PINGSTAT" add ok.test > /dev/null &
    wait
    [ "$(grep -cv '^#' "$XDG_CONFIG_HOME/pingstat/servers.list")" -eq 1 ]
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

@test "with several servers, reports are separated and -s shows just one" {
    servers ok.test two.test
    "$PINGSTAT" -p
    run "$PINGSTAT" -d
    [[ "$output" == *"'ok.test'"*"'two.test'"* ]]
    run "$PINGSTAT" -d -s two.test
    [[ "$output" != *"'ok.test'"* ]]
    run "$PINGSTAT" status -s two.test
    [ "${#lines[@]}" -eq 2 ]
}

@test "commands without servers say how to add one" {
    local args
    for args in "-p" "-d" "-o" "status" "prune --older-than 5"; do
        # shellcheck disable=SC2086
        run "$PINGSTAT" $args
        [ "$status" -eq 1 ]
        [[ "$output" == *"No servers in config."* ]]
        [[ "$output" == *"Add with 'pingstat add <server>'"* ]]
    done
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

@test "-p -q prints nothing unless something fails" {
    servers ok.test down.test nodns.test
    run "$PINGSTAT" -p -q
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(query ok.test 'SELECT COUNT(*) FROM ping_data;')" = "1" ]

    servers ok.test weird.test
    run "$PINGSTAT" -p -q
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: Could not measure weird.test"* ]]
    [[ "$output" != *"Pinged ok.test"* ]]
}

@test "-p -q shows why a result could not be stored" {
    servers ok.test
    mkdir -p "$DATA"
    echo "this is not a database, and long enough for sqlite to notice that it is not" > "$DATA/ok.test.db"
    run "$PINGSTAT" -p -q
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a database"* ]]
    [[ "$output" == *"ERROR: Run for ok.test failed."* ]]
}

@test "-q only works with -p" {
    servers ok.test
    run "$PINGSTAT" -d -q
    [ "$status" -eq 1 ]
    [[ "$output" == "Unknown argument '-q'."* ]]
}

@test "-p waits for another run that holds the database" {
    servers ok.test
    "$PINGSTAT" -p
    { echo "BEGIN EXCLUSIVE;"; sleep 2; echo "COMMIT;"; } | sqlite3 "$DATA/ok.test.db" &
    sleep 0.5
    run "$PINGSTAT" -p
    wait
    [ "$status" -eq 0 ]
    [ "$(query ok.test 'SELECT COUNT(*) FROM ping_data;')" = "2" ]
}

@test "--version warns instead of reporting a new version when offline" {
    run "$PINGSTAT" --version
    [[ "$output" == *"Current version:"* ]]
    [[ "$output" == *"Unable to determine the latest available version"* ]]
    [[ "$output" != *"New version available"* ]]
}

@test "--version reports the highest release tag" {
    # 50.10.0 is higher than 50.9.0, and other tag names are not releases
    release_tags 50.9.0 99.0.0-beta 50.10.0 v99.0.0
    run "$PINGSTAT" --version
    [[ "$output" == *"New version available: 50.10.0"* ]]
}

# --- Status ---

@test "status shows the last result of each server" {
    servers ok.test down.test nodns.test noroute.test weird.test new.test
    run "$PINGSTAT" -p
    run "$PINGSTAT" status
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" =~ ^server\ +last_run\ +state\ +down_since\ +loss$ ]]
    [[ "$output" =~ ok\.test\ +[0-9-]+\ [0-9:]+\ +up\ +-\ +25% ]]
    [[ "$output" =~ down\.test\ +[0-9-]+\ [0-9:]+\ +down\ +[0-9-]+\ [0-9:]+\ +100% ]]
    [[ "$output" =~ nodns\.test\ +[0-9-]+\ [0-9:]+\ +dns\ +[0-9-]+\ [0-9:]+\ +- ]]
    [[ "$output" =~ noroute\.test\ +[0-9-]+\ [0-9:]+\ +network\ +[0-9-]+\ [0-9:]+\ +- ]]
    [[ "$output" =~ weird\.test\ +[0-9-]+\ [0-9:]+\ +error\ +-\ +- ]]

    query new.test "DELETE FROM ping_data;"
    run "$PINGSTAT" status -s new.test
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[1]}" =~ new\.test\ +-\ +no\ data ]]
}

@test "status shows when the current failure began, after any monitoring gap" {
    new_db ok.test
    local m
    for m in 5040 5030 5020; do run_at ok.test "$m" 0; done
    run_at ok.test 5010 100     # before the gap: not part of the current failure
    run_at ok.test 20 100
    run_at ok.test 10 100
    run_at ok.test 5 NULL error  # measured nothing: still failing, not recovered
    run_at ok.test 0 100
    run "$PINGSTAT" status
    [[ "${lines[1]}" =~ down\ +$(run_minute ok.test 4) ]]
}

@test "status shows stale when runs have stopped" {
    new_db ok.test
    local m
    for m in 130 120 110 100; do run_at ok.test "$m" 100; done
    run "$PINGSTAT" status
    [[ "${lines[1]}" =~ stale\ +-\ +100% ]]
}

# --- on_change hook ---

# A hook that logs its arguments, and fails while $BATS_TEST_TMPDIR/hook-fails exists
hook() {
    HOOK_LOG="$BATS_TEST_TMPDIR/hook.log"
    cat > "$XDG_CONFIG_HOME/pingstat/on_change" <<EOF
#!/usr/bin/env bash
[ ! -e "$BATS_TEST_TMPDIR/hook-fails" ] || exit 1
printf '%s|' "\$@" >> "$HOOK_LOG"
echo >> "$HOOK_LOG"
EOF
    chmod +x "$XDG_CONFIG_HOME/pingstat/on_change"
}

@test "on_change hears of a failure after 3 failed runs, once, and of the recovery" {
    hook
    new_db ok.test
    run_at ok.test 30 0
    local since

    PING_STUB_DOWN=1 "$PINGSTAT" -p
    PING_STUB_DOWN=1 "$PINGSTAT" -p
    [ ! -e "$HOOK_LOG" ]

    PING_STUB_DOWN=1 "$PINGSTAT" -p
    PING_STUB_DOWN=1 "$PINGSTAT" -p
    [ "$(wc -l < "$HOOK_LOG")" -eq 1 ]
    since=$(query ok.test "SELECT datetime(MIN(timestamp), 'localtime') FROM ping_data WHERE loss >= 100;")
    [ "$(cat "$HOOK_LOG")" = "down|ok.test|no reply|$since|" ]

    "$PINGSTAT" -p
    [ "$(wc -l < "$HOOK_LOG")" -eq 2 ]
    [ "$(tail -n 1 "$HOOK_LOG")" = "up|ok.test|no reply|$since|0h 00m|" ]
    [ ! -e "$DATA/ok.test.down" ]

    "$PINGSTAT" -p
    [ "$(wc -l < "$HOOK_LOG")" -eq 2 ]
}

@test "on_change stays silent for a short failure" {
    hook
    new_db ok.test
    run_at ok.test 30 0
    PING_STUB_DOWN=1 "$PINGSTAT" -p
    PING_STUB_DOWN=1 "$PINGSTAT" -p
    "$PINGSTAT" -p
    [ ! -e "$HOOK_LOG" ]
}

@test "on_change names DNS and network errors" {
    hook
    servers nodns.test noroute.test
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    [[ "$(cat "$HOOK_LOG")" == *"down|nodns.test|dns|"* ]]
    [[ "$(cat "$HOOK_LOG")" == *"down|noroute.test|network|"* ]]
}

@test "on_change does not count failures from before a monitoring gap" {
    hook
    new_db ok.test
    local m
    for m in 5040 5030 5020; do run_at ok.test "$m" 0; done
    run_at ok.test 5010 100
    run_at ok.test 5000 100
    PING_STUB_DOWN=1 "$PINGSTAT" -p
    [ ! -e "$HOOK_LOG" ]
}

@test "on_change is not called for a failed measurement" {
    hook
    servers weird.test
    run "$PINGSTAT" -p
    run "$PINGSTAT" -p
    run "$PINGSTAT" -p
    [ ! -e "$HOOK_LOG" ]
}

@test "a failing on_change is an error and is tried again" {
    hook
    new_db ok.test
    run_at ok.test 30 0
    touch "$BATS_TEST_TMPDIR/hook-fails"
    PING_STUB_DOWN=1 "$PINGSTAT" -p
    PING_STUB_DOWN=1 "$PINGSTAT" -p
    PING_STUB_DOWN=1 run "$PINGSTAT" -p -q
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: The on_change hook failed for ok.test."* ]]
    [ "$(query ok.test 'SELECT COUNT(*) FROM ping_data;')" = "4" ]

    rm "$BATS_TEST_TMPDIR/hook-fails"
    PING_STUB_DOWN=1 run "$PINGSTAT" -p -q
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$HOOK_LOG")" -eq 1 ]
}

@test "on_change gets up when down never got through" {
    hook
    new_db ok.test
    run_at ok.test 40 0
    run_at ok.test 30 100
    run_at ok.test 20 100
    touch "$BATS_TEST_TMPDIR/hook-fails"
    PING_STUB_DOWN=1 run "$PINGSTAT" -p
    [ "$status" -eq 1 ]
    PING_STUB_DOWN=1 run "$PINGSTAT" -p
    [ "$status" -eq 1 ]
    rm "$BATS_TEST_TMPDIR/hook-fails"

    run "$PINGSTAT" -p
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$HOOK_LOG")" -eq 1 ]
    [[ "$(cat "$HOOK_LOG")" =~ ^up\|ok\.test\|no\ reply\|[0-9-]+\ [0-9:]+\|0h\ (29|30)m\|$ ]]
    [ ! -e "$DATA/ok.test.down" ]
}

@test "on_change tries up again until it gets through" {
    hook
    new_db ok.test
    run_at ok.test 60 0
    local m
    for m in 50 40 30; do run_at ok.test "$m" 100; done
    PING_STUB_DOWN=1 "$PINGSTAT" -p
    touch "$BATS_TEST_TMPDIR/hook-fails"
    run "$PINGSTAT" -p
    [ "$status" -eq 1 ]
    [ -e "$DATA/ok.test.down" ]
    rm "$BATS_TEST_TMPDIR/hook-fails"
    "$PINGSTAT" -p
    [ "$(wc -l < "$HOOK_LOG")" -eq 2 ]
    [ ! -e "$DATA/ok.test.down" ]
}

@test "on_change reports an unknown duration when monitoring stopped during a failure" {
    hook
    new_db ok.test
    local m
    for m in 5040 5030 5020; do run_at ok.test "$m" 0; done
    printf '%s\n%s\n%s\n' "no reply" "2026-01-01 10:00:00" "yes" > "$DATA/ok.test.down"
    run_at ok.test 5010 100
    "$PINGSTAT" -p
    [ "$(cat "$HOOK_LOG")" = "up|ok.test|no reply|2026-01-01 10:00:00|unknown|" ]
}

@test "on_change state files from 1.7.0 count as told" {
    hook
    new_db ok.test
    run_at ok.test 10 100
    printf '%s\n%s\n' "no reply" "2026-01-01 10:00:00" > "$DATA/ok.test.down"
    PING_STUB_DOWN=1 "$PINGSTAT" -p
    [ ! -e "$HOOK_LOG" ]
    "$PINGSTAT" -p
    [[ "$(cat "$HOOK_LOG")" == "up|ok.test|no reply|2026-01-01 10:00:00|"* ]]
}

@test "without on_change, -p makes no state files" {
    servers down.test
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    [ ! -e "$DATA/down.test.down" ]
}

# --- Settings ---

settings() {
    printf '%s\n' "$@" > "$XDG_CONFIG_HOME/pingstat/settings"
}

@test "on_change hears of a bad connection after 3 runs, once, and of the recovery" {
    hook
    settings "# limits" "alert_loss = 20"
    servers flap.test
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    [ ! -e "$HOOK_LOG" ]

    "$PINGSTAT" -p
    "$PINGSTAT" -p
    [ "$(wc -l < "$HOOK_LOG")" -eq 1 ]
    [[ "$(cat "$HOOK_LOG")" =~ ^degraded\|flap\.test\|loss\ 25%\|[0-9-]+\ [0-9:]+\|$ ]]

    PING_STUB_AS=good.busybox "$PINGSTAT" -p
    [ "$(wc -l < "$HOOK_LOG")" -eq 2 ]
    [[ "$(tail -n 1 "$HOOK_LOG")" =~ ^recovered\|flap\.test\|loss\ 25%\|[0-9-]+\ [0-9:]+\|0h\ 00m\|$ ]]
    [ ! -e "$DATA/flap.test.degraded" ]
}

@test "alert_latency compares the average latency" {
    hook
    settings "alert_latency=12.5"
    servers flap.test
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    [[ "$(cat "$HOOK_LOG")" == "degraded|flap.test|latency 12.5 ms|"* ]]
}

@test "a good run in between stops a bad connection from being reported" {
    hook
    settings "alert_loss=20"
    servers flap.test
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    PING_STUB_AS=good.busybox "$PINGSTAT" -p
    "$PINGSTAT" -p
    [ ! -e "$HOOK_LOG" ]
}

@test "runs without a reply are not a bad connection" {
    hook
    settings "alert_loss=20"
    new_db down.test
    run_at down.test 30 0
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    [ "$(wc -l < "$HOOK_LOG")" -eq 1 ]
    [[ "$(cat "$HOOK_LOG")" == "down|down.test|"* ]]
}

@test "a bad connection is not reported without limits in the settings" {
    hook
    servers flap.test
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    "$PINGSTAT" -p
    [ ! -e "$HOOK_LOG" ]
}

@test "settings warns about unknown keys and bad values and never executes the file" {
    settings "alert_loss=lots" "nonsense=1" "heartbeat_url=ftp://x" "touch $BATS_TEST_TMPDIR/executed"
    servers ok.test
    run "$PINGSTAT" list
    [[ "$output" == *"Ignoring 'alert_loss=lots'"* ]]
    [[ "$output" == *"Ignoring 'nonsense=1'"* ]]
    [[ "$output" == *"Ignoring 'heartbeat_url=ftp://x'"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/executed" ]
}

@test "-p calls the heartbeat URL when the run worked" {
    settings "heartbeat_url=https://hc.test/ping/abc?a=b"
    servers ok.test down.test
    run "$PINGSTAT" -p -q
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(grep -c 'https://hc.test/ping/abc?a=b' "$NET_LOG")" -eq 1 ]
}

@test "-p does not call the heartbeat URL when the run failed" {
    settings "heartbeat_url=https://hc.test/ping"
    servers weird.test
    run "$PINGSTAT" -p
    [ "$status" -eq 1 ]
    [ ! -e "$NET_LOG" ]
}

@test "reports do not call the heartbeat URL" {
    settings "heartbeat_url=https://hc.test/ping"
    servers ok.test
    "$PINGSTAT" -d
    "$PINGSTAT" status
    [ ! -e "$NET_LOG" ]
}

# --- Removing data ---

@test "remove --purge deletes everything of that server and nothing else" {
    servers ok.test ok.test2
    "$PINGSTAT" -p
    touch "$DATA/ok.test.down" "$DATA/ok.test.degraded" "$DATA/ok.test.db-journal"

    run "$PINGSTAT" remove ok.test --purge
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed server 'ok.test'."* ]]
    [[ "$output" == *"Deleted the data of 'ok.test'."* ]]
    [ -z "$(find "$DATA" -name 'ok.test.*')" ]
    [ -e "$DATA/ok.test2.db" ]
    [ "$(grep -v '^#' "$XDG_CONFIG_HOME/pingstat/servers.list")" = "ok.test2" ]

    run "$PINGSTAT" remove --purge ok.test2
    [ "$status" -eq 0 ]
    [ ! -e "$DATA/ok.test2.db" ]
}

@test "remove without a terminal keeps the data and says where" {
    servers ok.test
    "$PINGSTAT" -p
    run "$PINGSTAT" remove ok.test < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Data kept in $DATA/ok.test.db"* ]]
    [ -e "$DATA/ok.test.db" ]
}

@test "remove asks in a terminal, and deletes only on yes" {
    [ "$(uname)" = "Linux" ] && command -v script >/dev/null || skip "needs util-linux script"
    local answer
    for answer in "" n; do
        servers ok.test
        "$PINGSTAT" -p
        run script -qec "'$PINGSTAT' remove ok.test" /dev/null <<< "$answer"
        [[ "$output" == *"Also delete its data ("*" KB, since "*")? [y/N]"* ]]
        [[ "$output" == *"Data kept in"* ]]
        [ -e "$DATA/ok.test.db" ]
    done

    servers ok.test
    run script -qec "'$PINGSTAT' remove ok.test" /dev/null <<< "y"
    [[ "$output" == *"Deleted the data of 'ok.test'."* ]]
    [ ! -e "$DATA/ok.test.db" ]
}

@test "remove --purge cleans up a server that left the list earlier" {
    servers ok.test
    "$PINGSTAT" -p
    servers other.test
    run "$PINGSTAT" remove ok.test --purge
    [ "$status" -eq 0 ]
    [[ "$output" == *"Server 'ok.test' not found."* ]]
    [[ "$output" == *"Deleted the data of 'ok.test'."* ]]
    [ ! -e "$DATA/ok.test.db" ]
    [ "$(grep -v '^#' "$XDG_CONFIG_HOME/pingstat/servers.list")" = "other.test" ]
}

@test "remove --purge of an unknown server deletes nothing and says so" {
    run "$PINGSTAT" remove nothing.test --purge
    [ "$status" -eq 0 ]
    [ "$output" = "Server 'nothing.test' not found." ]
}

@test "remove refuses names that could leave the data directory" {
    mkdir -p "$DATA"
    touch "$DATA/../evil.db" "$DATA/../evil.down"
    local name
    for name in ../evil ../../evil a/b; do
        run "$PINGSTAT" remove "$name" --purge
        [ "$status" -eq 1 ]
        [[ "$output" == "Invalid server name '$name'."* ]]
    done
    [ -e "$DATA/../evil.db" ] && [ -e "$DATA/../evil.down" ]
}

@test "remove --purge waits for a run of that server" {
    command -v flock >/dev/null || skip "flock not installed"
    servers ok.test
    "$PINGSTAT" -p
    PING_STUB_SLEEP=2 "$PINGSTAT" -p > /dev/null &
    sleep 1
    "$PINGSTAT" remove ok.test --purge
    wait
    [ ! -e "$DATA/ok.test.db" ]
}

@test "remove without a server prints usage, and takes only one" {
    run "$PINGSTAT" remove --purge
    [ "$status" -eq 1 ]
    [ "$output" = "Usage: pingstat remove <server> [--purge]" ]
    run "$PINGSTAT" remove a.test b.test --purge
    [ "$status" -eq 1 ]
    [[ "$output" == "Unknown argument 'b.test'."* ]]
}

# --- Database size and pruning ---

# run_days_ago <server> <days>...
runs_days_ago() {
    local srv="$1" days
    shift
    for days in "$@"; do
        insert "$srv" "datetime('now', '-$days days'), 1, 2, 3, 0.5, 0"
    done
}

@test "list shows the size and age of each database" {
    servers ok.test new.test
    "$PINGSTAT" -p -s ok.test
    run "$PINGSTAT" list
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" =~ ^server\ +size\ +since\ +database$ ]]
    [[ "$output" =~ ok\.test\ +[0-9]+\ KB\ +[0-9]{4}-[0-9]{2}-[0-9]{2}\ +$DATA/ok\.test\.db ]]
    [[ "$output" =~ new\.test\ +-\ +-\ +$DATA/new\.test\.db ]]
    [ ! -e "$DATA/new.test.db" ]
}

@test "list survives a database it cannot read" {
    servers ok.test
    mkdir -p "$DATA"
    echo "this is not a database, and long enough for sqlite to notice that it is not" > "$DATA/ok.test.db"
    run "$PINGSTAT" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok.test"* ]]
}

@test "list and status warn about a database over max_db_size, -p does not" {
    settings "max_db_size=0.001"
    servers ok.test
    run "$PINGSTAT" -p
    [[ "$output" != *"WARNING"* ]]
    run "$PINGSTAT" -p -q
    [ -z "$output" ]
    run "$PINGSTAT" list
    [[ "$output" == *"WARNING: ok.test is "*" KB. Free space with: pingstat prune --older-than 1 -s ok.test"* ]]
    run "$PINGSTAT" status
    [[ "$output" == *"WARNING: ok.test is "* ]]
}

@test "the size warning suggests half the age of the data" {
    settings "max_db_size=0.001"
    new_db ok.test
    runs_days_ago ok.test 800 10
    run "$PINGSTAT" list
    [[ "$output" == *"pingstat prune --older-than 400 -s ok.test"* ]]

    # Nothing to suggest for a database it cannot read
    echo "this is not a database, and long enough for sqlite to notice that it is not" > "$DATA/ok.test.db"
    settings "max_db_size=0.00001"
    run "$PINGSTAT" list
    [[ "$output" == *"WARNING: ok.test is 0 KB."* ]]
    [[ "$output" != *"prune"* ]]
}

@test "no warning under the default limit or with max_db_size=0" {
    servers ok.test
    "$PINGSTAT" -p
    run "$PINGSTAT" list
    [[ "$output" != *"WARNING"* ]]
    settings "max_db_size=0"
    run "$PINGSTAT" list
    [[ "$output" != *"WARNING"* ]]
}

@test "prune deletes only old runs and shrinks the database" {
    new_db ok.test
    query ok.test "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
                   INSERT INTO ping_data(timestamp, avg, loss, status)
                   SELECT datetime('now', '-400 days', '-' || i || ' minutes'), 1, 0, 'ok' FROM n;"
    runs_days_ago ok.test 10
    local before after
    before=$(wc -c < "$DATA/ok.test.db")

    run "$PINGSTAT" prune --older-than 365 --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok.test: 20000 runs older than 365 days"* ]]
    [[ "$output" == *"Pruned ok.test: "*" KB -> "*" KB"* ]] || [[ "$output" == *"Pruned ok.test: "*" MB -> "*" KB"* ]]
    [ "$(query ok.test 'SELECT COUNT(*) FROM ping_data;')" = "1" ]
    after=$(wc -c < "$DATA/ok.test.db")
    [ "$after" -lt "$before" ]
}

@test "prune without a terminal refuses unless told --yes" {
    new_db ok.test
    runs_days_ago ok.test 400
    run "$PINGSTAT" prune --older-than 365 < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"Not deleted. Run this in a terminal, or add --yes."* ]]
    [ "$(query ok.test 'SELECT COUNT(*) FROM ping_data;')" = "1" ]
}

@test "prune asks in a terminal and deletes only on yes" {
    [ "$(uname)" = "Linux" ] && command -v script >/dev/null || skip "needs util-linux script"
    new_db ok.test
    runs_days_ago ok.test 400
    run script -qec "'$PINGSTAT' prune --older-than 365" /dev/null <<< "n"
    [[ "$output" == *"Nothing deleted."* ]]
    [ "$(query ok.test 'SELECT COUNT(*) FROM ping_data;')" = "1" ]

    run script -qec "'$PINGSTAT' prune --older-than 365" /dev/null <<< "y"
    [[ "$output" == *"Pruned ok.test"* ]]
    [ "$(query ok.test 'SELECT COUNT(*) FROM ping_data;')" = "0" ]
}

@test "prune -s touches one server, and works for a removed one" {
    new_db two.test
    runs_days_ago two.test 400
    new_db ok.test
    runs_days_ago ok.test 400
    servers ok.test

    run "$PINGSTAT" prune --older-than 365 -s two.test --yes
    [ "$status" -eq 0 ]
    [ "$(query two.test 'SELECT COUNT(*) FROM ping_data;')" = "0" ]
    [ "$(query ok.test 'SELECT COUNT(*) FROM ping_data;')" = "1" ]

    run "$PINGSTAT" prune --older-than 365 -s missing.test --yes
    [ "$status" -eq 1 ]
    [[ "$output" == "No database for 'missing.test'." ]]
    run "$PINGSTAT" prune --older-than 365 -s ../evil --yes
    [ "$status" -eq 1 ]
}

@test "prune says so when there is nothing to delete" {
    new_db ok.test
    runs_days_ago ok.test 10
    run "$PINGSTAT" prune --older-than 365
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to delete."* ]]
}

@test "prune needs a number of days of at least 1" {
    new_db ok.test
    local args
    for args in "prune" "prune --older-than" "prune --older-than 0" "prune --older-than x" "prune --yes"; do
        # shellcheck disable=SC2086
        run "$PINGSTAT" $args
        [ "$status" -eq 1 ]
        [[ "$output" == "Usage: pingstat prune "* ]]
    done
    run "$PINGSTAT" -d --older-than 5
    [ "$status" -eq 1 ]
    [[ "$output" == "Unknown argument '--older-than'."* ]]
    run "$PINGSTAT" -p --yes
    [ "$status" -eq 1 ]
}

@test "prune reports a database it cannot change, and goes on" {
    new_db a.test
    runs_days_ago a.test 400
    new_db b.test
    runs_days_ago b.test 400
    servers a.test b.test
    chmod 444 "$DATA/a.test.db"
    run "$PINGSTAT" prune --older-than 365 --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: Could not prune a.test."* ]]
    [[ "$output" == *"Pruned b.test"* ]]
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

    local old_month
    old_month=$(sqlite3 :memory: "SELECT strftime('%Y-%m', 'now', 'start of month', '-14 months');")
    run "$PINGSTAT" -m 12 -s ok.test
    [[ "$output" != *"$old_month"* ]]
    run "$PINGSTAT" -m 20 -s ok.test
    [[ "$output" == *"$old_month"* ]]
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
    [[ "$output" =~ $(run_minute ok.test 1).{4}\ +$(run_minute ok.test 4).{4}\ +0h\ 20m\ +3 ]]

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
    [[ "$output" =~ $(run_minute ok.test 1).{4}\ +$(run_minute ok.test 730).{4}\ +121h\ 30m\ +729\ +no\ reply ]]
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
    [[ "$output" =~ $(run_minute ok.test 6).{4}\ +0h\ 10m\ +1 ]]
    [[ "$output" =~ monitoring\ gap\ +0h\ 00m\ +1 ]]
}

@test "-o judges a monitoring gap the same way for every period" {
    new_db ok.test
    # A day of runs every minute, one failed run, 48 hours of nothing, a reply
    query ok.test "WITH RECURSIVE n(i) AS (SELECT 2881 UNION ALL SELECT i + 1 FROM n WHERE i < 4320)
                   INSERT INTO ping_data(timestamp, avg, loss, status)
                   SELECT datetime('now', '-' || i || ' minutes'), 1, 0, 'ok' FROM n;"
    run_at ok.test 2880 100
    run_at ok.test 0 0

    local n
    for n in 3 7; do
        run "$PINGSTAT" -o "$n" -s ok.test
        [[ "$output" =~ monitoring\ gap\ +0h\ 00m\ +1 ]]
    done
    # The last thing known about it is older than the period; never a 48-hour outage
    run "$PINGSTAT" -o 1 -s ok.test
    [[ "$output" == *"No outages."* ]]
}

@test "-o sees a monitoring gap with only a few runs" {
    new_db ok.test
    run_at ok.test 2882 0
    run_at ok.test 2881 0
    run_at ok.test 2880 100
    run_at ok.test 0 0
    run "$PINGSTAT" -o 3 -s ok.test
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

@test "install takes the highest release tag, an explicit version or main" {
    installed
    cp "$PINGSTAT" "$NET_STUB_FILE"
    release_tags 1.9.0 1.10.0
    PATH="$HOME/bin:$PATH" run bash "$BATS_TEST_DIRNAME/../install" < /dev/null
    [ "$status" -eq 0 ]
    grep -q "refs/tags/1.10.0/pingstat" "$NET_LOG"

    PATH="$HOME/bin:$PATH" run bash "$BATS_TEST_DIRNAME/../install" 1.4.1 < /dev/null
    grep -q "refs/tags/1.4.1/pingstat" "$NET_LOG"

    PATH="$HOME/bin:$PATH" run bash "$BATS_TEST_DIRNAME/../install" main < /dev/null
    grep -q "pingstat/main/pingstat" "$NET_LOG"
}

@test "install stops when it cannot find the latest version" {
    installed
    rm "$NET_STUB_TAGS"
    PATH="$HOME/bin:$PATH" run bash "$BATS_TEST_DIRNAME/../install" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unable to determine the latest version"* ]]
    [ "$(cat "$INSTALLED")" = "$OLD_CONTENT" ]
}

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
    grep -q "refs/tags/9.9.9/pingstat" "$NET_LOG"
    run grep "pingstat/main" "$NET_LOG"
    [ "$status" -eq 1 ]
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
    head -n 45 "$NET_STUB_FILE" > "$NET_STUB_FILE.cut"
    mv "$NET_STUB_FILE.cut" "$NET_STUB_FILE"
    run "$INSTALLED" --force-update
    [ "$status" -eq 1 ]
    [[ "$output" == *"not appear to be a valid pingstat script"* ]]
    [ "$(cat "$INSTALLED")" = "$before" ]
    [ "$(ls -A "$HOME/bin")" = "pingstat" ]
}

@test "--update refuses a download of another version" {
    installed
    cp "$PINGSTAT" "$INSTALLED"
    local before
    before=$(cat "$INSTALLED")
    sed 's/^VERSION=.*/VERSION="8.8.8"/' "$PINGSTAT" > "$NET_STUB_FILE"
    run "$INSTALLED" --update
    [ "$status" -eq 1 ]
    [[ "$output" == *"not appear to be a valid pingstat script"* ]]
    [ "$(cat "$INSTALLED")" = "$before" ]
}

@test "--force-update fails when the latest version is unknown" {
    installed
    cp "$PINGSTAT" "$INSTALLED"
    rm "$NET_STUB_TAGS"
    run "$INSTALLED" --force-update
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unable to determine the latest available version"* ]]
}
