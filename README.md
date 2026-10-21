# pingstat

[![CI](https://github.com/itstomsh/pingstat/actions/workflows/ci.yml/badge.svg)](https://github.com/itstomsh/pingstat/actions/workflows/ci.yml)

Long-term ping statistics from the command line, like `vnstat` for latency.

`pingstat` pings your servers from `cron`, stores the results in one SQLite database per server and
shows daily, monthly and hour-of-day summaries of latency, jitter and packet loss. It is a single
Bash script: no daemon, no web UI, no root.

```
$ pingstat -d 7 -s 192.168.1.1
----- Daily stats for '192.168.1.1' (last 7 days) -----

day         abs_min  avg_min  avg_avg  avg_max  abs_max  avg_jitter  avg_loss  weekday    num_pings
----------  -------  -------  -------  -------  -------  ----------  --------  ---------  ---------
2025-03-09  0.056    0.083    0.133    0.183    1.171    0.031       0.0%      Sunday     56
2025-03-08  0.052    0.084    0.132    0.182    0.323    0.029       0.0%      Saturday   96
2025-03-07  0.055    0.096    0.146    0.188    0.265    0.035       8.3%      Friday     96
2025-03-06  0.053    0.073    0.104    0.135    0.237    0.024       3.2%      Thursday   94
2025-03-05  0.055    0.084    0.128    0.167    0.235    0.030       0.0%      Wednesday  96
2025-03-04  0.056    0.090    0.138    0.191    1.111    0.033       1.0%      Tuesday    96
2025-03-03  0.054    0.097    0.142    0.183    0.231    0.034       5.4%      Monday     37
---------------------------------------------------------------------------------------------------

Note: Times are in milliseconds (ms), and packet loss in %.
```

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/itstomsh/pingstat/main/install -o install.sh
bash install.sh && rm install.sh   # or: sudo bash install.sh, for all users

pingstat add kernel.org
crontab -e                         # add: */5 * * * * pingstat -p
pingstat -d                        # a few days later
```

## Requirements

- `bash`, `ping` (iputils, BusyBox or BSD/macOS) and `sqlite3`
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

To install a specific version, pass it to the script: `bash install.sh 1.3.0`. Versions are listed in
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
| `pingstat -d [N]` | Daily stats for the last `N` days (default 20) |
| `pingstat -m [N]` | Monthly stats for the last `N` months (default 12) |
| `pingstat -H [N]` | Stats per hour of day over the last `N` days (default 7) |
| `-s <server>` | Limit `-p`, `-d`, `-m` or `-H` to one server |
| `--version`, `--update`, `--force-update` | Show the version, update to the latest one, reinstall it |
| `--uninstall` | Remove pingstat **and all its data** for your user |

```bash
pingstat -d 5 -s gnu.org   # last 5 days for gnu.org only
pingstat -H 30             # which hours of the day were worst in the last 30 days
```

### Stats columns

| Column | Meaning |
| --- | --- |
| `abs_min` / `abs_max` | Fastest / slowest single reply in the period |
| `avg_min` / `avg_max` | Average of each run's fastest / slowest reply |
| `avg_avg` | Average latency |
| `avg_jitter` | Average jitter (`mdev`, `stddev` on BSD/macOS); `-` on BusyBox, whose `ping` does not report it |
| `avg_loss` | Average packet loss |
| `weekday` | Day of the week (`-d` only) |
| `num_pings` | Number of runs in the period (each run sends 4 pings) |

Times are in milliseconds. Days, months and hours follow the machine's local time zone.

A run where the server does not answer, or its name does not resolve, is stored as 100% loss, so
outages show up in `avg_loss`. Latency columns show `-` when no run in the period got a reply.

## Running from cron

Ping all servers every 5 minutes (`crontab -e`):

```cron
*/5 * * * * pingstat -p
```

Or give a server its own schedule:

```cron
*/5 * * * * pingstat -p -s kernel.org
```

If a run is still pinging a server when the next one starts, the next run skips that server
(needs `flock`).

## Files

| Path | Contents |
| --- | --- |
| `~/.config/pingstat/servers.conf` | Server list (`SERVERS="kernel.org gnu.org"`) |
| `~/.local/share/pingstat/<server>.db` | Results for one server (SQLite, table `ping_data`, timestamps in UTC) |

Both honour `XDG_CONFIG_HOME` and `XDG_DATA_HOME`.

## Updating and uninstalling

```bash
pingstat --update      # uses sudo itself if pingstat is installed in /usr/bin
pingstat --uninstall   # removes the script, your config and all your data
```

To remove it by hand:

```bash
sudo rm /usr/bin/pingstat        # or: rm ~/bin/pingstat
rm -rf ~/.config/pingstat ~/.local/share/pingstat
```

Remove the `pingstat` line from your crontab as well.

## Troubleshooting

**`pingstat` exits without output.** `servers.conf` is read as Bash, so a syntax error in it stops the
script. Check that it is a single line like `SERVERS="kernel.org gnu.org"`, or delete it and add the
servers again; their data is kept.

**All latency columns show `-`.** Either the server never answered (see `avg_loss`), or your `ping`
prints a format pingstat does not recognise. Run `ping -c 4 <server>` and
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
