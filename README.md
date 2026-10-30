# pingstat

[![CI](https://github.com/itstomsh/pingstat/actions/workflows/ci.yml/badge.svg)](https://github.com/itstomsh/pingstat/actions/workflows/ci.yml)

Long-term ping statistics from the command line, like `vnstat` for latency.

`pingstat` pings your servers from `cron`, stores the results in one SQLite database per server and
shows daily, monthly and hour-of-day summaries of latency, jitter and packet loss, and a list of
outages. It is a single
Bash script: no daemon, no web UI, no root.

```
$ pingstat -d 7 -s 192.168.1.1
----- Daily stats for '192.168.1.1' (last 7 days) -----

day         abs_min  avg_min  avg_avg  avg_max  abs_max  avg_jitter  avg_loss  failed  weekday    num_pings
----------  -------  -------  -------  -------  -------  ----------  --------  ------  ---------  ---------
2025-03-09  0.056    0.083    0.133    0.183    1.171    0.031       0.0%      0       Sunday     56
2025-03-08  0.052    0.084    0.132    0.182    0.323    0.029       0.0%      0       Saturday   96
2025-03-07  0.055    0.096    0.146    0.188    0.265    0.035       8.3%      2       Friday     96
2025-03-06  0.053    0.073    0.104    0.135    0.237    0.024       3.2%      0       Thursday   94
2025-03-05  0.055    0.084    0.128    0.167    0.235    0.030       0.0%      0       Wednesday  96
2025-03-04  0.056    0.090    0.138    0.191    1.111    0.033       1.0%      0       Tuesday    96
2025-03-03  0.054    0.097    0.142    0.183    0.231    0.034       5.4%      0       Monday     37
-----------------------------------------------------------------------------------------------------------

Note: Times are in milliseconds (ms), and packet loss in %.
```

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/itstomsh/pingstat/main/install -o install.sh
bash install.sh && rm install.sh   # or: sudo bash install.sh, for all users

pingstat add kernel.org
crontab -e                         # add: * * * * * pingstat -p
pingstat -d                        # a few days later
```

## Requirements

- `bash`, `ping` (iputils, BusyBox or BSD/macOS) and `sqlite3` 3.25 or newer
- `curl` or `wget` for installing and updating
- `flock` (util-linux) is optional: with it, a run that is still pinging a server is not started twice

## Installation

The install script puts `pingstat` in `/usr/bin` when run with `sudo` (for all users), otherwise in
`~/bin` (it offers to add `~/bin` to your `PATH`). `pingstat` itself always runs as a normal user and
keeps its data per user.

```bash
curl -fsSL https://raw.githubusercontent.com/itstomsh/pingstat/main/install -o install.sh
sudo bash install.sh         # system-wide; or `bash install.sh` for your user only
rm install.sh
```

With `wget`, download it with `wget -q https://raw.githubusercontent.com/itstomsh/pingstat/main/install -O install.sh`.

To install a specific version, pass it to the script: `bash install.sh 1.5.1`. Versions are listed in
the [CHANGELOG](CHANGELOG.md).

> **Installed 1.1.0 or older?** Those versions look for updates on Codeberg, where pingstat is no
> longer published. Run the install script above once; your servers and data are kept.

## Usage

| Command | What it does |
| --- | --- |
| `pingstat add <server>` | Add a server (asks what to do if it does not answer a test ping) |
| `pingstat remove <server>` | Remove a server from the list (its data is kept) |
| `pingstat list` | List servers and their database files |
| `pingstat -p` | Ping all servers once (4 pings each, in parallel) and store the results |
| `pingstat -d [N]` | Daily stats for the last `N` calendar days, today included (default 20) |
| `pingstat -m [N]` | Monthly stats for the last `N` calendar months, this one included (default 12) |
| `pingstat -H [N]` | Stats per hour of day over the last `N` days (default 7) |
| `pingstat -o [N]` | Outages in the last `N` days (default 30) |
| `-s <server>` | Limit `-p`, `-d`, `-m`, `-H` or `-o` to one server |
| `--version`, `--update`, `--force-update` | Show the version, update to the latest one, reinstall it |
| `--uninstall` | Remove pingstat **and all its data** for your user (asks first) |

```bash
pingstat -d 5 -s gnu.org   # last 5 days for gnu.org only
pingstat -H 30             # which hours of the day were worst in the last 30 days
pingstat -o                # when the connection was down in the last 30 days
```

Server names must be host names or IP addresses (letters, digits, `.`, `-`, `:`; not starting with
`-` or `.`).

### Outages

An outage is a series of consecutive runs in which no ping got a reply, including runs that failed on
a DNS or network error, because those are often the same problem seen from here. `-o` shows when it
was first noticed, the first run that got a reply again, the time in between and the cause:

```
$ pingstat -o -s 192.168.1.1
----- Outages for '192.168.1.1' (last 30 days) -----

started              back_up              duration  failed_runs  cause
-------------------  -------------------  --------  -----------  --------
2025-03-07 21:10:01  2025-03-07 21:35:01  0h 25m    25           no reply
---------------------------------------------------------------------------

Note: An outage started at or before 'started' and ended by 'back_up'.
'monitoring gap': no runs after the last failed one, so the real end is unknown
and the duration stops at that run.
```

With a run every minute, the real start and end are up to a minute earlier. An outage that has not
ended yet shows `ongoing`.

`cause` is `no reply` (100% loss), `dns` (the name did not resolve), `network` (no route, e.g. the
machine's own connection is down) or `mixed`. Outages that began before the period keep their real
start and full duration.

If there are no runs for more than 3 times the usual interval (at least 3 minutes), for example
because the machine was off, nobody knows what happened in that time. An outage then ends at its last
failed run and `back_up` shows `monitoring gap` instead of counting the pause as downtime. The usual
interval is the median of the newest 1000 runs, whatever period you ask for. With fewer than a few
runs in the database there is no usual interval yet, so a gap may not show.

### Stats columns

| Column | Meaning |
| --- | --- |
| `abs_min` / `abs_max` | Fastest / slowest single reply in the period |
| `avg_min` / `avg_max` | Average of each run's fastest / slowest reply |
| `avg_avg` | Average latency |
| `avg_jitter` | Average jitter (`mdev`, `stddev` on BSD/macOS); `-` on BusyBox, whose `ping` does not report it |
| `avg_loss` | Average packet loss over the runs that were measured; `-` if none were |
| `failed` | Runs without a measurement: DNS or network error, or unrecognised `ping` output |
| `weekday` | Day of the week (`-d` only) |
| `num_pings` | Number of runs in the period (each run sends 4 pings) |

Times are in milliseconds. Days, months and hours follow the machine's local time zone.

A run where the server does not answer is stored as 100% loss. A run that sent no packets is not:
it is stored without loss, with a `status` saying why (`dns_error`, `net_error` or `error`), so it
counts in `failed` and not in `avg_loss`. Latency columns show `-` when no run in the period got a
reply. Runs from before 1.5.0 have no `status`; DNS errors among them stay stored as 100% loss.

## Running from cron

Ping all servers every minute (`crontab -e`):

```cron
* * * * * pingstat -p
```

Every minute is the recommended interval and the shortest cron allows. It catches outages of a minute
or two and dates them to the minute, while a run takes only about 3 seconds (4 pings, all servers in
parallel). Each server's database grows by about 1440 rows a day, roughly 30 MB a year.

A server can also have its own, less frequent schedule:

```cron
*/5 * * * * pingstat -p -s kernel.org
```

`pingstat -p` exits with status 1 if a result could not be stored or `ping` printed something it does
not recognise. The other servers are still pinged. A server that does not answer or does not resolve
is a result, not a failure: the exit status stays 0.

If a run is still pinging a server when the next one starts, the next run skips that server
(needs `flock`).

Without a terminal, as in cron, `pingstat` never asks anything: `-s` with a server that is not in
the list fails with a message instead of adding it, so a typo in a cron line cannot add a server.

## Files

| Path | Contents |
| --- | --- |
| `~/.config/pingstat/servers.list` | Server list, one per line (`#` starts a comment); edit it by hand or with `add`/`remove` |
| `~/.local/share/pingstat/<server>.db` | Results for one server (SQLite, table `ping_data`, timestamps in UTC; `status` is `ok`, `dns_error`, `net_error` or `error`) |

Both honour `XDG_CONFIG_HOME` and `XDG_DATA_HOME`.

## Updating and uninstalling

```bash
pingstat --update      # uses sudo itself if pingstat is installed in /usr/bin
pingstat --uninstall   # asks, then removes the script, your config and all your data
```

To remove it by hand:

```bash
sudo rm /usr/bin/pingstat        # or: rm ~/bin/pingstat
rm -rf ~/.config/pingstat ~/.local/share/pingstat
```

Remove the `pingstat` line from your crontab as well.

## Troubleshooting

**A server is missing from `list`.** `pingstat` warns about and skips lines in `servers.list` that are
not a valid host name or IP address. Fix the line; the server's data is kept.

**Upgrading from 1.3.0 or older.** The first run converts `servers.conf` to `servers.list` without
executing it and keeps the old file as `servers.conf.bak`.

**All latency columns show `-`.** Either the server never answered (see `avg_loss`) or nothing could
be measured (see `failed`).

**`ERROR: Could not measure <server>`.** Your `ping` failed or prints a format pingstat does not
recognise. Run `ping -c 4 <server>` and
[open an issue](https://github.com/itstomsh/pingstat/issues) with its output.

## Development

Tests use [bats](https://github.com/bats-core/bats-core) with a fake `ping` in `tests/bin/` and a real
`sqlite3`. Both checks run on every push in GitHub Actions:

```bash
shellcheck pingstat install tests/bin/* tests/*.bats
bats tests
```

## License

[MIT](LICENSE)
