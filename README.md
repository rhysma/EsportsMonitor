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
    ├── windows/
    │   ├── Install-Server.ps1       installs/upgrades the server as a background task
    │   └── web.config               IIS reverse proxy (HTTPS stays on your existing IIS)
    └── linux/                       equivalents for a Linux server, if you ever move it
```

The PCs only make **outbound HTTPS** requests to the server, so it can live anywhere
on the internet — no campus firewall changes or inbound ports on the lab network.

---

## 1. Set up the server on your Windows Lightsail instance

The monitor is tiny (a few MB of RAM) and runs alongside whatever else the instance hosts.
It listens only on `127.0.0.1:8080`; your existing IIS + HTTPS sits in front of it.
Nothing new needs opening in the Lightsail or Windows firewall.

### a. Install Python (one time)
Download Python 3.9+ from python.org. In the installer choose **Customize installation →
Install Python for all users** (the background task can't use a per-user or Microsoft Store Python).

### b. Install the server
Copy the unzipped kit to the instance, open **PowerShell as Administrator** in the kit folder, and run:

```powershell
.\deploy\windows\Install-Server.ps1
```

The first run copies the files to `C:\EsportsMonitor\server`, prints a random key you can
use, and stops so you can fill in the settings.

### c. Edit `C:\EsportsMonitor\server\config.json`
- **`agent_key`** – paste the random key the script printed. Every PC uses this to report.
- **`dashboard_password`** – required (the server won't start without it, since it's internet-facing).
  The browser asks for it; any username works.
- **`dashboard_url`** – the HTTPS address staff will use (it's linked in Discord alerts).
- Leave `listen_host` at `127.0.0.1` and `behind_proxy` at `true`.

Run `.\deploy\windows\Install-Server.ps1` again. It checks the config, registers a scheduled
task (**Esports Monitor Server**) that runs at startup and restarts itself if it ever stops,
and confirms the server is answering. Re-running it later upgrades the code without
touching your config or data.

### d. Point IIS at it
One-time IIS setup:
1. Install **URL Rewrite** and **Application Request Routing 3.0** (both free from Microsoft's IIS site).
2. IIS Manager → click the **server** node → **Application Request Routing Cache** →
   **Server Proxy Settings** (right side) → tick **Enable proxy** → Apply.

Then pick one:

**Option 1 – its own hostname (cleanest), e.g. `esports-monitor.yourdomain.com`.**
Add a DNS record for it pointing at the instance's static IP, create a new IIS site with an
HTTPS binding for that name (same certificate if it's a wildcard, or issue one the way you
did for your other site), point the site at an empty folder, and copy
`deploy\windows\web.config` into that folder.

**Option 2 – a path on a site you already have, e.g. `https://yoursite.com/esports/`.**
Add these two rules at the **top** of that site's `<rewrite><rules>` in its web.config
(or create them in IIS Manager → URL Rewrite):

```xml
<rule name="Esports Monitor slash" stopProcessing="true">
  <match url="^esports$" />
  <action type="Redirect" url="esports/" />
</rule>
<rule name="Esports Monitor" stopProcessing="true">
  <match url="^esports/(.*)" />
  <action type="Rewrite" url="http://127.0.0.1:8080/{R:1}" />
</rule>
```

Use `https://yoursite.com/esports` as the server URL for the PCs. (The dashboard's
**Remove** button uses an HTTP DELETE; if it fails with a 405, WebDAV is enabled on that
site — the dedicated-site option avoids this.)

For whichever site you use: **Authentication → Anonymous on, Basic and Windows auth off**,
otherwise IIS intercepts the dashboard password.

Check it: open your HTTPS address and enter the dashboard password.

**Files and logs:** data is in `C:\EsportsMonitor\server\monitor.db` and the server log is
`monitor.log` next to it. Lightsail snapshots cover both; deleting the database just resets the dashboard.

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
- Using the path option? The server URL is `https://yoursite.com/esports`.
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
  All traffic is HTTPS via IIS; the Python server itself only listens on localhost.
- After 10 wrong keys or passwords in 15 minutes, that IP address is locked out for 15 minutes.
- The server refuses to start with the placeholder key or (when internet-facing) without a dashboard password.
- If the agent key ever leaks, change it in `config.json` and re-run `Install-Agent.ps1` on
  the PCs with the new key. The worst someone could do with it is send fake reports.
- The only data that leaves campus is PC names, which apps are installed, disk space, and
  Windows version. No student names, logins, or activity. Worth mentioning to IT if they
  have a policy on off-site hosting.
- The agent only reads file/registry/launcher info and disk space. It doesn't record who
  is logged in or what anyone is doing.
