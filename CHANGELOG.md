# Changelog

All notable changes to **pingstat** will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

---

## [1.7.2] - 2026-10-30
### Fixed
- macOS and BSD: `add` gave the test ping 3 milliseconds instead of 3 seconds, so servers looked unreachable
- Bash before 4.4, like the one on macOS: an empty server list stopped `add` and `remove` with an error
- The install script no longer needs `realpath -m`, which macOS does not have

### Changed
- CI also runs the tests on macOS and Alpine

---

## [1.7.1] - 2026-10-30
### Added
- `on_change` gets a fifth argument with `up`: how long the failure lasted, or `unknown` if monitoring stopped during it

### Fixed
- A failure whose `down` could not be sent, like the machine's own connection going down, was never reported. The first reply afterwards now sends `up` with the start and the duration

---

## [1.7.0] - 2026-10-30
### Added
- Notifications: `-p` calls the executable `~/.config/pingstat/on_change` when a server goes down (after 3 failed runs in a row) and when it comes back

---

## [1.6.0] - 2026-10-30
### Added
- `-q` with `-p`: print only errors, so `cron` mails you only when something is wrong. Change your cron line to `pingstat -p -q`
- `pingstat status`: the last result of each server, since when it has been failing, and `stale` when runs have stopped arriving

### Changed
- `--update`, `--version` and the install script now use the highest version tag instead of `main`, so a push to `main` no longer reaches users. They read the tags from the GitHub API. `bash install.sh main` still installs the development version
- `--update` refuses a download whose version is not the expected one, and `--force-update` fails instead of reinstalling `main` when the latest version is unknown

### Fixed
- A run that found the database in use by another run failed right away. It now waits up to 10 seconds

---

## [1.5.1] - 2026-10-30
### Changed
- Unknown or extra arguments are now an error with exit status 1, before anything runs. Check your cron lines: one with a typo used to run and now fails

### Fixed
- `-o` could show a monitoring gap as an outage, depending on N: `-o 1` reported 48 hours for a pause that `-o 7` recognised. The usual interval between runs now comes from the newest 1000 runs, not from the period
- `add` or `remove` at the same time could lose one of the changes while both reported success (needs `flock`)
- `pingstat -p -S server` pinged all servers, and `-d 7x` showed the default 20 days, because unknown arguments were ignored

---

## [1.5.0] - 2026-10-30
### Added
- `failed` column in `-d`, `-m` and `-H`: runs without a measurement
- `cause` column in `-o`: `no reply`, `dns`, `network` or `mixed`
- `-o` shows `monitoring gap` when there are no runs for more than 3 typical intervals (at least 3 minutes) after a failed run

### Changed
- DNS errors, network errors and unrecognised `ping` output are no longer stored as 100% loss, but without a loss value and with a new `status` column (added to existing databases automatically; existing rows are unchanged). They no longer raise `avg_loss`; DNS and network errors still count as outages in `-o`, unrecognised output does not
- `-d N` and `-m N` now mean the last N calendar days and months, today and this month included

### Fixed
- `-p` exited with status 0 when a result could not be stored. It now exits with status 1 when storing fails or `ping` output is not recognised, and still pings the other servers
- `-d N` and `-m N` showed the last N days and months that have data, however old
- `-o` counted a stopped monitor as downtime: a last failed run stayed `ongoing` for ever, and a pause during an outage was added to its duration
- `-o` gave an outage that began before the period a later start and a shorter duration, depending on N
- An interrupted install could leave a broken `pingstat`, and a failed install with `wget` deleted the existing one. The install script and `--update` now check the download and replace the script in one step
- `--update` exited with status 0 when the download was invalid

---

## [1.4.1] - 2026-10-21
### Fixed
- Without a terminal (e.g. in cron), `-s` with a server that is not in the list added it to the list, because the unanswered "add it now? [Y/n]" prompt counted as yes. It now fails with a message; `add` of a server that does not answer fails as well instead of waiting for an answer
- `-o` was slow on large databases (5.5 s for 30 days and 87 s for a year of runs every minute; now 0.1 s and 1.2 s): databases get an index on `timestamp`, added to existing ones automatically, and the query no longer searches the whole table for every outage

---

## [1.4.0] - 2026-10-21
### Added
- `-o [N]`: list outages (consecutive runs with 100% loss) in the last N days (default 30)

### Changed
- The server list is now `servers.list`, one server per line with `#` comments, and is no longer executed as Bash. `servers.conf` is converted automatically on the first run and kept as `servers.conf.bak`
- `add` accepts only host names and IP addresses, so a name can no longer be passed to `ping` as an option or escape the data directory
- `--uninstall` asks for confirmation before deleting anything

### Fixed
- The `add` prompt offered "(a,d,c)" instead of "(a,n,c)"

---

## [1.3.0] - 2026-10-21
### Added
- `-H [N]`: stats per hour of day over the last N days (default 7)
- `avg_jitter` column (average `mdev`) in all stats views
- Support for BusyBox and BSD/macOS `ping` output
- Tests (bats) and ShellCheck, run in GitHub Actions

### Changed
- `-p` pings all servers in parallel and prints the results in config order
- A server whose previous ping is still running is skipped instead of pinged twice (uses `flock` when available)

### Fixed
- The install script no longer exits when creating the install directory fails, but asks again

---

## [1.2.0] - 2026-10-21
### Changed
- Moved from Codeberg to GitHub (`github.com/itstomsh/pingstat`): install and update now download from there. Installs of 1.1.0 or older still check Codeberg, so reinstall once with the install script from the README
- The latest version is fetched only by `--version`, `--update` and `--force-update`, not on every run (with a 10 s timeout)
- Daily and monthly stats are grouped by local time instead of UTC
- Latency columns show `-` instead of `0.000` when no ping got a reply

### Fixed
- The install script fails instead of installing an error page when the download fails (e.g. an unknown version)
- Outages are recorded as 100% loss: `-p` no longer skips pinging when 8.8.8.8/1.1.1.1 are unreachable, and a ping with no reply no longer aborts the script before saving
- `--version` no longer reports "New version available: unknown" when offline
- `add` and `-s` without an argument print usage instead of crashing

---

## [1.1.0] - 2025-03-21
### Added
- Automatic version detection from script (removed external `VERSION` file)
- Interactive prompt when using `-p`, `-d`, or `-m` with `-s <server>` for unknown servers
- Safe and user-friendly uninstall routine
- Compatibility with `set -euo pipefail` for strict and safe Bash scripting
- Default server limits for daily and monthly stats (20/12)
- Troubleshooting section in README

### Changed
- Version checking and update logic refactored into standalone function
- Improved argument parsing for robustness and script safety
- Refactored `add_server` and `do_ping_all` to prevent unwanted `.db` creation
- Better detection of `sudo` vs non-sudo installs
- README install section uses temp download with cleanup

### Fixed
- Script no longer crashes on undefined variables when run with strict mode
- Prevents pinging or logging for unconfirmed or declined servers
- Handles missing config file (`servers.conf`) gracefully

---

## [1.0.0] - 2025-03-09
Initial public release

- Basic add/remove/list server support
- Daily and monthly ping statistics
- Server-specific SQLite databases
- `--update`, `--uninstall`, `--version` flags
