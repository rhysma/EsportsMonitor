# Ozarks Tech Esports – PC Install Monitor

Each esports PC checks every 15 minutes that the competition titles and apps are
installed and playable, then reports to a small server. Staff see every PC on one
dashboard, and (optionally) get a Discord message the moment something goes missing
and again when it's fixed.

**Tracked by default:** Valorant, Riot Vanguard, Overwatch, Rocket League, Fortnite,
Marvel Rivals, Apex Legends, Spotify, Discord — plus free disk space on every drive,
since a full disk is what usually triggers the uninstalls.

```
esports-monitor/
├── server/
│   ├── server.py         collector + dashboard (Python 3.9+, no extra packages)
│   ├── dashboard.html    the staff web page
│   └── config.json       apps, detection rules, alerts, thresholds
├── agent/
│   ├── Check-EsportsInstalls.ps1   the check that runs on each PC
│   ├── Install-Agent.ps1           one-time setup per PC
│   └── Uninstall-Agent.ps1
└── deploy/
    ├── esports-monitor.service     systemd unit (auto-start, auto-restart)
    ├── Caddyfile                   HTTPS for a server with nothing else on 80/443
    └── nginx-esports-monitor.conf  HTTPS for a server already running nginx
```

The PCs only make **outbound HTTPS** requests to the server, so it can live anywhere
on the internet — no campus firewall changes or inbound ports on the lab network.

---

## 1. Set up the server on AWS Lightsail

The monitor is tiny (a few MB of RAM), so it can share an existing Lightsail instance
with your other projects. These steps assume a Linux (Ubuntu/Debian) instance.

### a. Give it a hostname
HTTPS certificates need a DNS name. Create a record such as
`esports-monitor.yourdomain.com` pointing at the instance's **static IP**
(Lightsail → Networking → attach a static IP if the instance doesn't have one).

### b. Open the firewall
Lightsail → your instance → **Networking → IPv4 Firewall**: allow **HTTPS (443)** and
**HTTP (80)** (80 is only used to obtain the certificate). Do **not** open 8080 — the
monitor listens on localhost only and the web server in front of it handles the internet.

### c. Copy the files and create a service account
```bash
sudo mkdir -p /opt/esports-monitor
sudo cp -r server deploy /opt/esports-monitor/        # from the unzipped folder
sudo useradd --system --no-create-home esportsmon
sudo chown -R esportsmon:esportsmon /opt/esports-monitor/server
python3 --version                                      # needs 3.9+; Ubuntu 22.04+ is fine
```

### d. Edit `/opt/esports-monitor/server/config.json`
- **`agent_key`** – a long random string. Generate one with
  `python3 -c "import secrets; print(secrets.token_urlsafe(32))"`. The server won't start with the placeholder.
- **`dashboard_password`** – required (the server won't start without it, since it's internet-facing).
  The browser asks for it; any username works.
- **`dashboard_url`** – `https://esports-monitor.yourdomain.com` (linked in Discord alerts).
- Leave `listen_host` at `127.0.0.1` and `behind_proxy` at `true`.

### e. Run it as a service
```bash
sudo cp /opt/esports-monitor/deploy/esports-monitor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now esports-monitor
sudo systemctl status esports-monitor          # should say "active (running)"
```

### f. Put HTTPS in front
**Already running nginx for your other projects?** Use `deploy/nginx-esports-monitor.conf`
(instructions are in the file), then `sudo certbot --nginx -d esports-monitor.yourdomain.com`.

**Nothing on ports 80/443 yet?** Install Caddy (`sudo apt install caddy`), put the contents of
`deploy/Caddyfile` (with your hostname) in `/etc/caddy/Caddyfile`, and
`sudo systemctl reload caddy`. Caddy gets and renews the certificate automatically.

Check it: open `https://esports-monitor.yourdomain.com` and enter the dashboard password.

Data is stored in `monitor.db` (SQLite) next to `server.py`. Lightsail's automatic
snapshots cover it; deleting it just resets the dashboard.

## 2. Install the agent on each esports PC

From an **elevated** PowerShell window, in the `agent` folder:

```powershell
.\Install-Agent.ps1 -ServerUrl https://esports-monitor.yourdomain.com -AgentKey '<your agent_key>'
```

It first confirms it can reach the server with that key (and stops with a clear message if
not, e.g. if the campus network is blocking the address). Then it copies the script to `C:\Program Files\EsportsMonitor`, stores the key where only
admins/SYSTEM can read it, and creates a scheduled task (**Esports Install Monitor**) that
runs as SYSTEM at startup and every 15 minutes. The PC appears on the dashboard within a minute.

- Different interval: add `-IntervalMinutes 10`.
- **Deep Freeze / reboot-restore software:** install while the PC is thawed, or the task disappears on reboot.
- Troubleshooting log on the PC: `C:\ProgramData\EsportsMonitor\agent.log`.
- Test on a PC without sending anything:
  `.\Check-EsportsInstalls.ps1 -ConfigPath ..\server\config.json -DryRun`

## 3. Turn on Discord alerts (optional, recommended)

In your staff Discord server: **Channel settings → Integrations → Webhooks → New Webhook**,
copy the URL, and paste it into `discord_webhook_url` in `config.json`. No restart needed.

You'll get messages like:

> 🔴 **ESPORTS-PC07**: Fortnite is not installed
> 🟡 **ESPORTS-PC04**: Drive C: is low on space (12 GB free)
> ✅ **ESPORTS-PC07**: Fortnite is installed again

Alerts fire only when something *changes*, so a PC that stays broken doesn't spam the channel.
Set `alert_on_warnings` to `false` for missing-game alerts only. `alert_on_offline` is off by
default because PCs are shut down overnight; offline PCs still show grey on the dashboard.

---

## Reading the dashboard

| Mark | Meaning |
|---|---|
| ✓ green | Installed and playable |
| ✕ red | Missing, or the launcher lists it but the files are gone (**Problem**) |
| ! amber | Installed but an update/repair is pending, or the check couldn't run (**Warning**) |
| ? grey | That PC hasn't checked this app yet (new app added; it'll fill in on the next run) |

Hover any mark to see exactly what was found (e.g. which Steam library, or why it failed).
Click the tiles at the top to filter. **Remove** drops a retired PC from the dashboard.

## How detection works

Each app has a list of rules; if any rule finds a working install, the app passes. The agent
prefers the healthiest evidence (a good Steam copy beats a broken Epic leftover).

| Rule type | What it checks | Catches |
|---|---|---|
| `steam` | `appmanifest_<appid>.acf` in every Steam library + the game folder | Uninstalls, deleted folders, stuck/failed updates |
| `epic` | Epic launcher manifests + install folder + game .exe | Uninstalls, missing files, incomplete installs |
| `file` | A specific file exists (`<ANYDRIVE>` = every drive, `<USERPROFILE>` = every user profile, `*` wildcards ok) | Riot, Battle.net, per-user apps like Discord/Spotify |
| `uninstall` | Windows "Installed apps" entry, and its folder still exists | Battle.net / EA app installs |
| `appx` | Microsoft Store package | Store version of Spotify |
| `service` | A Windows service exists | Riot Vanguard (`vgc`) |

**Adding a title:** add an entry to `apps` in `config.json` on the server. PCs pick up the
new list on their next run — no need to touch the PCs. Find a Steam app ID in the game's
store URL (`store.steampowered.com/app/<id>/`).

If a game is installed somewhere unusual on your PCs and shows as missing, hover the ✕ to
see what was checked, then add a `file` rule with the right path.

## Security notes

- Agents authenticate with the shared `agent_key`; the dashboard with `dashboard_password`.
  All traffic is HTTPS via Caddy/nginx; the Python server itself only listens on localhost.
- After 10 wrong keys or passwords in 15 minutes, that IP address is locked out for 15 minutes.
- The server refuses to start with the placeholder key or (when internet-facing) without a dashboard password.
- If the agent key ever leaks, change it in `config.json` and re-run `Install-Agent.ps1` on
  the PCs with the new key. The worst someone could do with it is send fake reports.
- The only data that leaves campus is PC names, which apps are installed, disk space, and
  Windows version. No student names, logins, or activity. Worth mentioning to IT if they
  have a policy on off-site hosting.
- The agent only reads file/registry/launcher info and disk space. It doesn't record who
  is logged in or what anyone is doing.
