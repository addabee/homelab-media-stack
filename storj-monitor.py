#!/usr/bin/env python3
"""Storj storage node health monitor.

Alerts only on STATE CHANGES (problem appears / problem clears) so cron can run
it often without spamming. Lives on the root filesystem on purpose: if the
storage array fails to mount, this must still be able to run and complain.
"""
import json, os, shutil, subprocess, sys, urllib.request
from datetime import datetime, timezone

API        = "http://127.0.0.1:14002/api/sno/"
STATE_FILE = os.path.expanduser("~/.local/state/storj-monitor.json")
CONF_FILE  = os.path.expanduser("~/.config/storj-monitor.conf")
DATA_DIR   = "/mnt/calculon/storj/data"

CFG = {
    "NTFY_SERVER":       "https://ntfy.sh",
    "NTFY_TOPIC":        "",       # set in conf file
    "NTFY_EMAIL":        "",       # optional: ntfy forwards to this address. REQUIRES an
                                   # ntfy account + NTFY_TOKEN -- ntfy.sh rejects
                                   # anonymous email sending with HTTP 400.
    "NTFY_TOKEN":        "",       # ntfy access token, needed only for NTFY_EMAIL
    "NOTIFY_CMD":        "",       # optional: overrides ntfy; gets body on stdin, title as $1
    "PING_MAX_MIN":      "20",     # satellites should ping well inside this
    "DISK_USED_PCT":     "90",     # alert when allocation this full
    "ARRAY_FREE_MIN_GB": "250",    # alert when the array itself gets this tight
    "SCORE_MIN":         "0.96",   # audit/suspension score floor
}
if os.path.exists(CONF_FILE):
    for line in open(CONF_FILE):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            CFG[k.strip()] = v.strip().strip('"').strip("'")

def notify(title, body, priority="default"):
    if CFG["NOTIFY_CMD"]:
        subprocess.run(CFG["NOTIFY_CMD"], shell=True, input=f"{title}\n{body}".encode(),
                       env={**os.environ, "STORJ_TITLE": title})
        return
    if CFG["NTFY_TOPIC"]:
        headers = {"Title": title, "Priority": priority, "Tags": "satellite"}
        # ntfy forwards to email when this header is present -- lets the monitor
        # reach you with no app installed.
        if CFG["NTFY_EMAIL"]:
            headers["Email"] = CFG["NTFY_EMAIL"]
        if CFG["NTFY_TOKEN"]:
            headers["Authorization"] = f'Bearer {CFG["NTFY_TOKEN"]}'
        req = urllib.request.Request(
            f'{CFG["NTFY_SERVER"].rstrip("/")}/{CFG["NTFY_TOPIC"]}',
            data=body.encode("utf-8"),
            headers=headers)
        try:
            urllib.request.urlopen(req, timeout=15)
        except Exception as e:
            print(f"notify failed: {e}", file=sys.stderr)
        return
    print(f"[{title}] {body}", file=sys.stderr)

if "--selftest" in sys.argv:
    # The failure mode this exists for: a misconfigured notifier fails silently,
    # leaving a monitor that looks healthy and can never reach you.
    print("sending a test alert through the real notify() path...")
    ok = {"v": True}
    _orig = notify
    def notify(title, body, priority="default"):      # noqa: F811
        try:
            _orig(title, body, priority)
        except Exception as e:
            ok["v"] = False; print(f"  FAILED: {e}")
    notify("storj-monitor selftest",
           "If you are reading this, alerts can reach you.", "default")
    print("  posted -- confirm you actually received it." if ok["v"]
          else "  DELIVERY FAILED -- alerts would not reach you.")
    sys.exit(0 if ok["v"] else 1)

problems = {}   # key -> human message
def flag(key, msg): problems[key] = msg

# --- storage array present? (checked first: everything else is moot if not) ---
if not os.path.isdir(DATA_DIR):
    flag("array_missing", f"{DATA_DIR} does not exist — the array may not be mounted. "
                          "The node cannot serve data and will fail audits.")
else:
    du = shutil.disk_usage("/mnt/calculon")
    free_gb = du.free / 1e9
    if free_gb < float(CFG["ARRAY_FREE_MIN_GB"]):
        flag("array_low", f"Array free space is {free_gb:.0f} GB, below the "
                          f'{CFG["ARRAY_FREE_MIN_GB"]} GB floor. A full disk fails audits.')

# --- node API ---
data = None
try:
    with urllib.request.urlopen(API, timeout=20) as r:
        data = json.load(r)
except Exception as e:
    flag("api_down", f"Node dashboard unreachable ({e}). Container is probably stopped.")

if data:
    if data.get("quicStatus") != "OK":
        flag("quic", f'QUIC is "{data.get("quicStatus")}", not OK. UDP 28967 is likely no '
                     "longer reaching the node — check the gateway forward and that this "
                     "host still holds its expected LAN address.")
    lp = data.get("lastPinged")
    if lp:
        try:
            t = datetime.fromisoformat(lp.replace("Z", "+00:00"))
            mins = (datetime.now(timezone.utc) - t).total_seconds() / 60
            if mins > float(CFG["PING_MAX_MIN"]):
                flag("stale_ping", f"No satellite contact for {mins:.0f} minutes. "
                                   "The node is probably unreachable from the internet.")
        except Exception:
            pass
    ds = data.get("diskSpace") or {}
    alloc, used = ds.get("available", 0), ds.get("used", 0)
    if alloc and (used / alloc) * 100 > float(CFG["DISK_USED_PCT"]):
        flag("alloc_full", f"Allocation {used/alloc*100:.0f}% full "
                           f"({used/1e12:.2f} of {alloc/1e12:.2f} TB).")
    if data.get("upToDate") is False:
        flag("outdated", f'Node version {data.get("version")} is out of date.')
    for s in (data.get("satellites") or []):
        url = s.get("url", "?")
        if s.get("disqualified"):
            flag(f"dq:{url}", f"DISQUALIFIED on {url}. This is permanent.")
        if s.get("suspended"):
            flag(f"susp:{url}", f"SUSPENDED on {url} — fix before it becomes disqualification.")
    for s in (data.get("audits") or []):
        url = s.get("satelliteName", "?")
        for label, key in (("audit", "auditScore"), ("suspension", "suspensionScore"),
                           ("online", "onlineScore")):
            v = s.get(key)
            if isinstance(v, (int, float)) and v < float(CFG["SCORE_MIN"]):
                flag(f"score:{key}:{url}", f"{label} score on {url} is {v:.3f}.")

# --- diff against last run, alert only on change ---
prev = {}
if os.path.exists(STATE_FILE):
    try: prev = json.load(open(STATE_FILE)).get("problems", {})
    except Exception: pass

new      = {k: v for k, v in problems.items() if k not in prev}
resolved = [k for k in prev if k not in problems]

if new:
    notify(f"Storj node: {len(new)} new issue{'s' if len(new) > 1 else ''}",
           "\n\n".join(new.values()), priority="high")
if resolved:
    notify("Storj node recovered",
           "Cleared:\n" + "\n".join(f"- {prev[k]}" for k in resolved), priority="low")

os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
json.dump({"problems": problems, "checked": datetime.now(timezone.utc).isoformat()},
          open(STATE_FILE, "w"), indent=2)

if problems:
    print(f"{len(problems)} problem(s):")
    for k, v in problems.items(): print(f"  [{k}] {v}")
    sys.exit(1)
print("all checks passed")
