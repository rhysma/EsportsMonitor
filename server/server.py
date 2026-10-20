#!/usr/bin/env python3
"""
Ozarks Tech Esports install monitor - server and dashboard.

Receives reports from the PC agents, tracks which PCs are missing required
games/apps or are low on disk space, sends Discord alerts when something
breaks or gets fixed, and serves the staff dashboard.

Standard library only (Python 3.9+). Run:  python server.py
Settings live in config.json next to this file and are re-read automatically
when the file changes, so editing the app list doesn't need a restart.
"""
import base64
import hmac
import json
import os
import sqlite3
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

BASE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("MONITOR_CONFIG", os.path.join(BASE, "config.json"))
DB_PATH = os.environ.get("MONITOR_DB", os.path.join(BASE, "monitor.db"))
DASHBOARD_PATH = os.path.join(BASE, "dashboard.html")
MAX_BODY = 1_000_000
PLACEHOLDER_KEY = "CHANGE-ME-to-a-long-random-string"
FAIL_LIMIT = 10          # bad key/password attempts allowed per IP...
FAIL_WINDOW = 15 * 60    # ...within this many seconds, before the IP is locked out


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


# --------------------------------------------------------------------------
# Config (hot-reloaded on change)
# --------------------------------------------------------------------------
_cfg = {"mtime": None, "data": None}
_cfg_lock = threading.Lock()


def config():
    with _cfg_lock:
        try:
            mtime = os.path.getmtime(CONFIG_PATH)
            if mtime != _cfg["mtime"]:
                with open(CONFIG_PATH, encoding="utf-8") as f:
                    _cfg["data"] = json.load(f)
                if _cfg["mtime"] is not None:
                    log("config.json reloaded")
                _cfg["mtime"] = mtime
        except (OSError, ValueError) as e:
            if _cfg["data"] is None:
                raise
            log(f"config.json could not be read ({e}); keeping previous settings")
        return _cfg["data"]


# --------------------------------------------------------------------------
# Database
# --------------------------------------------------------------------------
_db = None
_db_lock = threading.Lock()


def init_db():
    global _db
    _db = sqlite3.connect(DB_PATH, check_same_thread=False, timeout=10)
    _db.row_factory = sqlite3.Row
    _db.executescript(
        """
        CREATE TABLE IF NOT EXISTS pcs (
            hostname   TEXT PRIMARY KEY,
            first_seen REAL NOT NULL,
            last_seen  REAL NOT NULL,
            report     TEXT NOT NULL,
            issue_keys TEXT NOT NULL DEFAULT '[]',
            offline    INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS events (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            ts       REAL NOT NULL,
            hostname TEXT NOT NULL,
            kind     TEXT NOT NULL,
            message  TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        """
    )
    _db.commit()


def add_events(rows):
    now = time.time()
    _db.executemany(
        "INSERT INTO events(ts, hostname, kind, message) VALUES (?,?,?,?)",
        [(now, h, k, m) for (h, k, m) in rows],
    )
    # keep the log from growing forever
    _db.execute("DELETE FROM events WHERE ts < ?", (now - 90 * 86400,))


# --------------------------------------------------------------------------
# Issue logic
# --------------------------------------------------------------------------
def compute_issues(report, cfg):
    """Turn a PC report into a list of issues using the current config."""
    issues = []
    results = {a.get("id"): a for a in report.get("apps", []) if isinstance(a, dict)}

    for app in cfg.get("apps", []):
        r = results.get(app["id"])
        if r is None:
            continue  # agent hasn't picked up this app yet
        name = app.get("name", app["id"])
        if not r.get("installed"):
            if r.get("error"):
                issues.append({"key": f"checkfail:{app['id']}", "severity": "warning",
                               "message": f"Couldn't check {name}: {r['error']}"})
            else:
                detail = r.get("detail") or ""
                extra = f" ({detail})" if detail and detail != "Not found" else ""
                issues.append({"key": f"missing:{app['id']}", "severity": "problem",
                               "message": f"{name} is not installed{extra}"})
        elif r.get("needs_attention"):
            issues.append({"key": f"attention:{app['id']}", "severity": "warning",
                           "message": f"{name}: {r.get('detail') or 'update or repair pending'}"})

    low = float(cfg.get("low_disk_gb", 40))
    for d in report.get("disks", []):
        try:
            free = float(d.get("free_gb"))
        except (TypeError, ValueError):
            continue
        if free < low:
            issues.append({"key": f"disk:{d.get('drive')}", "severity": "warning",
                           "message": f"Drive {d.get('drive')} is low on space ({free:.0f} GB free)"})
    return issues


def describe_resolved(key, cfg):
    kind, _, ident = key.partition(":")
    names = {a["id"]: a.get("name", a["id"]) for a in cfg.get("apps", [])}
    name = names.get(ident, ident)
    if kind == "missing":
        return f"{name} is installed again"
    if kind == "attention":
        return f"{name} finished updating"
    if kind == "checkfail":
        return f"{name} can be checked again"
    if kind == "disk":
        return f"Drive {ident} has enough free space again"
    return f"{key} cleared"


def status_for(issues, online):
    if not online:
        return "offline"
    if any(i["severity"] == "problem" for i in issues):
        return "problem"
    if issues:
        return "warning"
    return "ok"


# --------------------------------------------------------------------------
# Alerts
# --------------------------------------------------------------------------
def send_discord(text):
    cfg = config()
    url = (cfg.get("discord_webhook_url") or "").strip()
    if not url or not text:
        return

    def go():
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps({"content": text[:1900]}).encode(),
                headers={"Content-Type": "application/json", "User-Agent": "OTC-Esports-Monitor/1.0"},
            )
            urllib.request.urlopen(req, timeout=10).read()
        except Exception as e:  # never let alerting break reporting
            log(f"Discord alert failed: {e}")

    threading.Thread(target=go, daemon=True).start()


def alert_changes(host, new_issues, resolved_msgs, cfg):
    lines = []
    for i in new_issues:
        if i["severity"] == "problem":
            lines.append(f"\U0001F534 **{host}**: {i['message']}")
        elif cfg.get("alert_on_warnings", True):
            lines.append(f"\U0001F7E1 **{host}**: {i['message']}")
    for m in resolved_msgs:
        lines.append(f"✅ **{host}**: {m}")
    if lines:
        link = cfg.get("dashboard_url")
        send_discord("\n".join(lines) + (f"\n<{link}>" if link else ""))


# --------------------------------------------------------------------------
# Report handling
# --------------------------------------------------------------------------
def handle_report(rep):
    host = str(rep.get("hostname", "")).strip().upper()[:64]
    if not host or not isinstance(rep.get("apps"), list):
        raise ValueError("report needs hostname and apps")
    cfg = config()
    now = time.time()
    rep["received_at"] = now
    issues = compute_issues(rep, cfg)
    keys = {i["key"] for i in issues}

    with _db_lock:
        row = _db.execute("SELECT issue_keys, offline FROM pcs WHERE hostname=?", (host,)).fetchone()
        prev = set(json.loads(row["issue_keys"])) if row else set()
        events = []
        if row is None:
            events.append((host, "info", f"{host} reported in for the first time"))
        elif row["offline"]:
            events.append((host, "online", f"{host} is back online"))

        new_issues = [i for i in issues if i["key"] not in prev]
        resolved_msgs = [describe_resolved(k, cfg) for k in sorted(prev - keys)]
        events += [(host, i["severity"], i["message"]) for i in new_issues]
        events += [(host, "resolved", m) for m in resolved_msgs]

        _db.execute(
            """INSERT INTO pcs(hostname, first_seen, last_seen, report, issue_keys, offline)
               VALUES (?,?,?,?,?,0)
               ON CONFLICT(hostname) DO UPDATE SET
                 last_seen=excluded.last_seen, report=excluded.report,
                 issue_keys=excluded.issue_keys, offline=0""",
            (host, now, now, json.dumps(rep), json.dumps(sorted(keys))),
        )
        if events:
            add_events(events)
        _db.commit()

    if row is not None and row["offline"] and cfg.get("alert_on_offline"):
        resolved_msgs = resolved_msgs + ["back online"]
    alert_changes(host, new_issues, resolved_msgs, cfg)
    return len(issues)


def offline_watcher():
    while True:
        try:
            cfg = config()
            cutoff = time.time() - float(cfg.get("offline_after_minutes", 45)) * 60
            with _db_lock:
                gone = [r["hostname"] for r in _db.execute(
                    "SELECT hostname FROM pcs WHERE offline=0 AND last_seen < ?", (cutoff,))]
                if gone:
                    _db.executemany("UPDATE pcs SET offline=1 WHERE hostname=?", [(h,) for h in gone])
                    add_events([(h, "offline", f"{h} stopped reporting") for h in gone])
                    _db.commit()
            if gone and cfg.get("alert_on_offline"):
                send_discord("\n".join(f"⚫ **{h}** stopped reporting (offline or agent not running)" for h in gone))
        except Exception as e:
            log(f"offline watcher error: {e}")
        time.sleep(60)


def status_payload():
    cfg = config()
    now = time.time()
    window = float(cfg.get("offline_after_minutes", 45)) * 60
    with _db_lock:
        rows = _db.execute("SELECT * FROM pcs ORDER BY hostname").fetchall()
        events = _db.execute("SELECT ts, hostname, kind, message FROM events ORDER BY id DESC LIMIT 60").fetchall()

    pcs = []
    for r in rows:
        rep = json.loads(r["report"])
        issues = compute_issues(rep, cfg)  # recomputed so config edits apply immediately
        online = (now - r["last_seen"]) < window
        pcs.append({
            "hostname": r["hostname"],
            "status": status_for(issues, online),
            "online": online,
            "last_seen": r["last_seen"],
            "first_seen": r["first_seen"],
            "issues": issues,
            "apps": rep.get("apps", []),
            "disks": rep.get("disks", []),
            "os": rep.get("os"),
            "agent_version": rep.get("agent_version"),
            "last_boot": rep.get("last_boot"),
        })
    return {
        "generated_at": now,
        "apps": [{"id": a["id"], "name": a.get("name", a["id"])} for a in cfg.get("apps", [])],
        "settings": {
            "low_disk_gb": cfg.get("low_disk_gb", 40),
            "offline_after_minutes": cfg.get("offline_after_minutes", 45),
            "discord": bool((cfg.get("discord_webhook_url") or "").strip()),
        },
        "pcs": pcs,
        "events": [dict(e) for e in events],
    }


# --------------------------------------------------------------------------
# Brute-force protection
# --------------------------------------------------------------------------
_fails = {}
_fails_lock = threading.Lock()


def is_locked_out(ip):
    now = time.time()
    with _fails_lock:
        recent = [t for t in _fails.get(ip, []) if now - t < FAIL_WINDOW]
        if recent:
            _fails[ip] = recent
        else:
            _fails.pop(ip, None)
        return len(recent) >= FAIL_LIMIT


def record_failure(ip):
    with _fails_lock:
        _fails.setdefault(ip, []).append(time.time())
        if len(_fails[ip]) == FAIL_LIMIT:
            log(f"Locking out {ip} for {FAIL_WINDOW // 60} minutes after {FAIL_LIMIT} failed logins")


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "OTCEsportsMonitor/1.0"

    def log_message(self, fmt, *args):
        if os.environ.get("MONITOR_VERBOSE"):
            log(f"{self.client_ip()} {fmt % args}")

    def client_ip(self):
        ip = self.client_address[0]
        # Behind Caddy/nginx on the same box, the real client is the last X-Forwarded-For entry
        if config().get("behind_proxy") and ip in ("127.0.0.1", "::1"):
            fwd = self.headers.get("X-Forwarded-For", "")
            if fwd:
                ip = fwd.split(",")[-1].strip()
        return ip

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def _agent_ok(self):
        given = self.headers.get("X-Agent-Key", "")
        ok = hmac.compare_digest(given.encode(), str(config().get("agent_key", "")).encode())
        if not ok:
            record_failure(self.client_ip())
        return ok

    def _staff_ok(self):
        pw = config().get("dashboard_password") or ""
        if not pw:
            return True
        h = self.headers.get("Authorization", "")
        if not h.startswith("Basic "):
            return False  # first visit: browser hasn't sent a password yet, not a failure
        try:
            given = base64.b64decode(h[6:]).decode().partition(":")[2]
        except Exception:
            given = ""
        ok = hmac.compare_digest(given.encode(), pw.encode())
        if not ok:
            record_failure(self.client_ip())
        return ok

    def _need_staff(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Esports Monitor"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _locked(self):
        if is_locked_out(self.client_ip()):
            self._send(429, {"error": "too many failed attempts; try again later"})
            return True
        return False

    def do_GET(self):
        if self._locked():
            return
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            if not self._staff_ok():
                return self._need_staff()
            with open(DASHBOARD_PATH, "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if path == "/api/status":
            if not self._staff_ok():
                return self._need_staff()
            return self._send(200, status_payload())
        if path == "/api/config":
            if not self._agent_ok():
                return self._send(403, {"error": "bad agent key"})
            cfg = config()
            return self._send(200, {"apps": cfg.get("apps", [])})
        if path == "/healthz":
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if self._locked():
            return
        path = urlparse(self.path).path
        if path != "/api/report":
            return self._send(404, {"error": "not found"})
        if not self._agent_ok():
            return self._send(403, {"error": "bad agent key"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > MAX_BODY:
                raise ValueError("bad length")
            raw = self.rfile.read(length).decode("utf-8-sig")
            n = handle_report(json.loads(raw))
        except (ValueError, json.JSONDecodeError) as e:
            return self._send(400, {"error": str(e)})
        return self._send(200, {"ok": True, "issues": n})

    def do_DELETE(self):
        if self._locked():
            return
        path = urlparse(self.path).path
        if not path.startswith("/api/pcs/"):
            return self._send(404, {"error": "not found"})
        if not self._staff_ok():
            return self._need_staff()
        host = unquote(path[len("/api/pcs/"):]).strip().upper()
        with _db_lock:
            cur = _db.execute("DELETE FROM pcs WHERE hostname=?", (host,))
            if cur.rowcount:
                add_events([(host, "info", f"{host} removed from the dashboard")])
            _db.commit()
        return self._send(200, {"ok": True, "removed": bool(cur.rowcount)})


def main():
    cfg = config()
    key = str(cfg.get("agent_key") or "")
    host = cfg.get("listen_host", "0.0.0.0")
    exposed = cfg.get("behind_proxy") or host not in ("127.0.0.1", "localhost", "::1")
    if key == PLACEHOLDER_KEY or len(key) < 20:
        log("ERROR: set agent_key in config.json to a long random value (20+ characters) before starting.\n"
            '       Generate one with:  python3 -c "import secrets; print(secrets.token_urlsafe(32))"')
        return 1
    if exposed and not cfg.get("dashboard_password"):
        if cfg.get("behind_proxy"):
            log("ERROR: dashboard_password is empty. This server is internet-facing, so a password is required.")
            return 1
        log("WARNING: dashboard_password is empty; anyone who can reach this server can view the dashboard.")
    init_db()
    threading.Thread(target=offline_watcher, daemon=True).start()
    port = int(cfg.get("listen_port", 8080))
    srv = ThreadingHTTPServer((host, port), Handler)
    log(f"Esports Monitor listening on http://{host}:{port}  (Ctrl+C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("stopping")


if __name__ == "__main__":
    sys.exit(main())
