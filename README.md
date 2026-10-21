# pingstat

A lightweight, user-level script for multi-server ping logging, storing stats per server in user-writable SQLite databases.

---

## Example Output

```bash
pingstat -d
```

```bash
day         abs_min  avg_min  avg_avg  avg_max  abs_max  avg_loss  weekday    num_pings
----------  -------  -------  -------  -------  -------  --------  ---------  ---------
2025-03-09  0.056    0.083    0.133    0.183    1.171    0.0%      Sunday     56       
2025-03-08  0.052    0.084    0.132    0.182    0.323    0.0%      Saturday   96       
2025-03-07  0.055    0.096    0.146    0.188    0.265    8.3%      Friday     96       
2025-03-06  0.053    0.073    0.104    0.135    0.237    3.2%      Thursday   94       
2025-03-05  0.055    0.084    0.128    0.167    0.235    0.0%      Wednesday  96       
2025-03-04  0.056    0.090    0.138    0.191    1.111    1.0%      Tuesday    96       
2025-03-03  0.054    0.097    0.142    0.183    0.231    5.4%      Monday     37       
2025-03-02  0.058    0.079    0.124    0.179    0.316    12.5%     Sunday     24       
2025-03-01  0.059    0.087    0.132    0.174    0.223    4.2%      Saturday   24       
2025-02-28  0.060    0.085    0.136    0.184    0.229    0.0%      Friday     28       
2025-02-27  0.056    0.063    0.093    0.135    0.168    0.0%      Thursday   4        
-------------------------------------------------------------------------------------

Note: Times are in milliseconds (ms), and packet loss in %.
```

### **Stat Definitions**

- **abs_min** – absolute minimum (quickest response of the day/month).
- **avg_min** – average minimum ping over the day.
- **avg_avg** – average ping of all requests for that day.
- **avg_max** – average of the maximum ping values recorded.
- **abs_max** – absolute maximum (the slowest response recorded).
- **avg_loss** – average packet loss percentage for the day/month.
- **weekday** – day of the week (only for the -d flag).
- **num_pings** – number of pings for the day/month.

Days and months follow the machine's local time zone. A run where the server does not answer is recorded as 100% loss, so outages are part of the stats; its latency columns show `-` when no ping of the day/month got a reply.

---

## Features

✅ **Manage multiple servers** (`add`, `remove`, `list`) without manually editing config files.  
✅ **Log ping statistics** (`min/avg/max/mdev/loss`) into a dedicated SQLite `.db` file per server.  
✅ **View historical stats** with daily (`-d`) or monthly (`-m`) aggregation.  
✅ **Minimal dependencies** – requires only `bash`, `ping`, `sqlite3`, and `curl` or `wget` (for install).  
✅ **Automate pings** using `cron` for long-term monitoring.  

---

## Installation

### **System-wide Installation** (Requires `sudo` but only for installation!)

```bash
wget -q "https://raw.githubusercontent.com/itstomsh/pingstat/main/install" -O install.sh && sudo bash install.sh && rm install.sh
```
or (if you prefer curl):

```bash
curl -sL "https://raw.githubusercontent.com/itstomsh/pingstat/main/install" -o install.sh && sudo bash install.sh && rm install.sh
```

This installs `pingstat` in `/usr/bin/`, making it available to all users.

### **User-Level Installation** (No `sudo`)

```bash
wget -q "https://raw.githubusercontent.com/itstomsh/pingstat/main/install" -O install.sh && bash install.sh && rm install.sh
```

or:

```bash
curl -sL "https://raw.githubusercontent.com/itstomsh/pingstat/main/install" -o install.sh && bash install.sh && rm install.sh
```
*(Ensure `~/bin` is in your `$PATH` to run `pingstat` easily.)*

### **Install a Specific Version** (e.g., `1.2.0`)

```bash
wget -q "https://raw.githubusercontent.com/itstomsh/pingstat/main/install" -O install.sh && sudo bash install.sh 1.2.0 && rm install.sh
```

or:

```bash
curl -sL "https://raw.githubusercontent.com/itstomsh/pingstat/main/install" -o install.sh && sudo bash install.sh 1.2.0 && rm install.sh
```

---

## Basic Usage

```bash
pingstat <command> [options]
```

### **Server Management**
- `pingstat add <server>` → Add a server (e.g., `kernel.org`).  
- `pingstat remove <server>` → Remove a server from the list.  
- `pingstat list` → List all configured servers.  

### **Ping & Stats**
- `pingstat -p` → Ping all servers (or use `-s <server>` for one).  
- `pingstat -d [N]` → Show daily stats for the last `N` days (default: 20).  
- `pingstat -m [N]` → Show monthly stats for the last `N` months (default: 12).  
- `pingstat -s <server>` → Apply `-p`, `-d`, or `-m` to a specific server.  

### **Examples**
```bash
pingstat add kernel.org
pingstat add gnu.org
pingstat list
```

```bash
pingstat -p        # Ping all servers
pingstat -p -s gnu.org  # Ping only gnu.org
pingstat -d 5      # Show last 5 days' stats
pingstat -d 5 -s gnu.org  # Last 5 days for gnu.org only
pingstat remove gnu.org  # Remove gnu.org from the list
```

---

## Automating with Cron

To ping **all** servers every **5 minutes**, edit your crontab (`crontab -e`) and add:

```cron
*/5 * * * * pingstat -p
```

For a single server:

```cron
*/5 * * * * pingstat -p -s kernel.org
```

---

## Updating

To update to the latest version:

```bash
pingstat --update
```

Or manually by running install script as described above.

---

## Uninstalling

To remove `pingstat`, run:

```bash
pingstat --uninstall
```

Or manually remove:

```bash
sudo rm /usr/bin/pingstat  # System-wide install
rm -rf ~/.config/pingstat        # User config
rm -rf ~/.local/share/pingstat   # User data
```
*(Adjust paths if you installed locally.)*

---
## Troubleshooting

### Script exits silently with no output?

If you're using a custom config or modified version, ensure your config file is valid Bash syntax:

```bash
cat ~/.config/pingstat/servers.conf
```
A working config might look like:
```bash
SERVERS="kernel.org gnu.org"
```
If it's empty or corrupted, just delete it:
```bash
rm ~/.config/pingstat/servers.conf
```
If that doesn’t help, try reinstalling `pingstat` (this will not delete your current data):
```bash
pingstat --force-update
```
And if that still doesn’t help, there may be a bug in the script (oops — my fault 😅).
As a quick workaround, you can comment out this line in the script:
```bash
set -euo pipefail
```
⚠️ Only do this if you know what you’re doing, and please open an issue so I can fix the root cause.

## License

Licensed under [MIT](LICENSE).
