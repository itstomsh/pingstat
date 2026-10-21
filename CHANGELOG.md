# Changelog

All notable changes to **pingstat** will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

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
