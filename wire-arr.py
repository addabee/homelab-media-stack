#!/usr/bin/env python3
"""
Wire Prowlarr <-> Sonarr <-> Radarr <-> qBittorrent.

Run from the media-server host (talks to the published ports on localhost):
    python3 /mnt/calculon/media-stack/wire-arr.py

Idempotent: existing resources with the same name are left alone.
Container-to-container hostnames used in the configs:
    sonarr:8989  radarr:7878  lidarr:8686  prowlarr:9696
    gluetun:8080 (qBittorrent)  gluetun:8191 (FlareSolverr)

Quality profiles are NOT set here -- they are owned by recyclarr/recyclarr.yml
for Sonarr and Radarr. Lidarr's profile is still set in its web UI.
"""
import json, sys, urllib.request, urllib.error, re, pathlib

APP = "/mnt/calculon/media-stack/appdata"
def apikey(name):
    """Read a service's API key. Returns None if the service has never been
    started (no config.xml yet) so one missing app cannot abort the whole run."""
    cfg = pathlib.Path(f"{APP}/{name}/config.xml")
    if not cfg.is_file():
        return None
    m = re.search(r"<ApiKey>([^<]+)</ApiKey>", cfg.read_text())
    return m.group(1) if m else None

SONARR = ("http://localhost:8989", apikey("sonarr"),  "v3")
RADARR = ("http://localhost:7878", apikey("radarr"),  "v3")
LIDARR = ("http://localhost:8686", apikey("lidarr"),  "v1")
PROWL  = ("http://localhost:9696", apikey("prowlarr"),"v1")

def call(base, ver, path, method="GET", body=None):
    url = f"{base}/api/{ver}/{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
        headers={"X-Api-Key": call.keys[base], "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        print(f"  ! {method} {path} -> HTTP {e.code}: {e.read().decode()[:300]}")
        return None
call.keys = {SONARR[0]: SONARR[1], RADARR[0]: RADARR[1],
             LIDARR[0]: LIDARR[1], PROWL[0]: PROWL[1]}

# Lidarr is optional (guarded at its call sites); these three are not.
_missing = [n for n, k in (("sonarr", SONARR[1]), ("radarr", RADARR[1]),
                           ("prowlarr", PROWL[1])) if not k]
if _missing:
    sys.exit(f"No API key for: {', '.join(_missing)}. "
             f"Expected <ApiKey> in {APP}/<app>/config.xml -- start the "
             f"container and open its web UI once, then re-run.")

def schema_entry(base, ver, path, impl):
    for s in call(base, ver, path) or []:
        if s.get("implementation") == impl:
            return s
    return None

def set_fields(entry, overrides):
    for f in entry.get("fields", []):
        if f["name"] in overrides:
            f["value"] = overrides[f["name"]]
    return entry

def have(base, ver, path, name):
    return any(x.get("name") == name for x in (call(base, ver, path) or []))

# ---------------------------------------------------------------- root folders
def root_folder(app, path):
    base, key, ver = app
    existing = [r["path"] for r in call(base, ver, "rootfolder") or []]
    if path in existing:
        print(f"  root folder {path} already present"); return
    r = call(base, ver, "rootfolder", "POST", {"path": path})
    print(f"  + root folder {path}" if r else f"  ! failed root folder {path}")

def lidarr_root_folder(path):
    """Lidarr's rootfolder POST needs a name plus default quality/metadata
    profile ids -- unlike Sonarr/Radarr, a bare {"path": ...} is rejected."""
    base, key, ver = LIDARR
    if path in [r["path"] for r in call(base, ver, "rootfolder") or []]:
        print(f"  root folder {path} already present"); return
    qps = call(base, ver, "qualityprofile") or []
    mps = call(base, ver, "metadataprofile") or []
    if not qps or not mps:
        print("  ! Lidarr has no quality/metadata profiles yet -- "
              "open its UI once, then re-run"); return
    r = call(base, ver, "rootfolder", "POST", {
        "name": "Music", "path": path,
        "defaultQualityProfileId": qps[0]["id"],
        "defaultMetadataProfileId": mps[0]["id"],
        "defaultMonitorOption": "all", "defaultNewItemMonitorOption": "all",
        "defaultTags": [],
    })
    print(f"  + root folder {path}" if r else f"  ! failed root folder {path}")

# ------------------------------------------------------------- download client
def qbit_client(app, category, prio_fields):
    base, key, ver = app
    if have(base, ver, "downloadclient", "qBittorrent"):
        print("  qBittorrent download client already present"); return
    e = schema_entry(base, ver, "downloadclient/schema", "QBittorrent")
    if not e:
        print("  ! no QBittorrent schema"); return
    ov = {"host": "gluetun", "port": 8080, "useSsl": False,
          "username": "", "password": "", "initialState": 0}
    ov[prio_fields["cat"]] = category
    set_fields(e, ov)
    e.update({"enable": True, "name": "qBittorrent"})
    r = call(base, ver, "downloadclient?forceSave=true", "POST", e)
    print(f"  + qBittorrent download client (category={category})" if r else "  ! failed download client")

# --------------------------------------------------------------------- naming
def naming(app, patch):
    base, key, ver = app
    cur = call(base, ver, "config/naming")
    cur.update(patch)
    r = call(base, ver, f"config/naming/{cur['id']}", "PUT", cur)
    print("  naming updated" if r is not None else "  ! naming update failed")

# ============================================================================
print("== Sonarr ==")
root_folder(SONARR, "/data/media/tv")
qbit_client(SONARR, "sonarr", {"cat": "tvCategory"})
naming(SONARR, {
    "renameEpisodes": True,
    "standardEpisodeFormat": "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Quality Full}]",
    "dailyEpisodeFormat":    "{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Quality Full}]",
    "animeEpisodeFormat":    "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Quality Full}]",
    "seriesFolderFormat": "{Series TitleYear}",
    "seasonFolderFormat": "Season {season:00}",
    "specialsFolderFormat": "Season 00",
})

print("== Radarr ==")
root_folder(RADARR, "/data/media/movies")
qbit_client(RADARR, "radarr", {"cat": "movieCategory"})
naming(RADARR, {
    "renameMovies": True,
    "standardMovieFormat": "{Movie CleanTitle} ({Release Year}) [{Quality Full}]",
    "movieFolderFormat": "{Movie CleanTitle} ({Release Year})",
})

print("== Lidarr ==")
if LIDARR[1]:
    lidarr_root_folder("/data/media/music")
    qbit_client(LIDARR, "music", {"cat": "musicCategory"})
    # Lidarr has no albumFolderFormat -- the album folder is part of the track
    # format path. Produces  Artist/Album (Year)/01 - Track.flac  per
    # MEDIA-STRUCTURE.md. https://wiki.servarr.com/lidarr/settings
    naming(LIDARR, {
        "renameTracks": True,
        "artistFolderFormat": "{Artist Name}",
        "standardTrackFormat":
            "{Album Title} ({Release Year})/{track:00} - {Track Title}",
        "multiDiscTrackFormat":
            "{Album Title} ({Release Year})/CD{medium:00}/{track:00} - {Track Title}",
    })
else:
    print("  skipped -- no appdata/lidarr/config.xml yet "
          "(docker compose up -d lidarr, open the UI once, re-run)")

print("== Prowlarr ==")
pb, pk, pv = PROWL
# FlareSolverr tag
tags = {t["label"]: t["id"] for t in call(pb, pv, "tag") or []}
if "flaresolverr" not in tags:
    t = call(pb, pv, "tag", "POST", {"label": "flaresolverr"})
    tags["flaresolverr"] = t["id"]
    print("  + tag 'flaresolverr'")
fs_tag = tags["flaresolverr"]

# FlareSolverr proxy
if not have(pb, pv, "indexerproxy", "FlareSolverr"):
    e = schema_entry(pb, pv, "indexerproxy/schema", "FlareSolverr")
    set_fields(e, {"host": "http://gluetun:8191/", "requestTimeout": 60})
    e.update({"name": "FlareSolverr", "tags": [fs_tag]})
    r = call(pb, pv, "indexerproxy", "POST", e)
    print("  + FlareSolverr proxy" if r else "  ! FlareSolverr proxy failed")
else:
    print("  FlareSolverr proxy already present")

# qBittorrent download client in Prowlarr (for its own manual grabs)
if not have(pb, pv, "downloadclient", "qBittorrent"):
    e = schema_entry(pb, pv, "downloadclient/schema", "QBittorrent")
    set_fields(e, {"host": "gluetun", "port": 8080, "useSsl": False,
                   "username": "", "password": "", "category": "prowlarr"})
    e.update({"enable": True, "name": "qBittorrent"})
    r = call(pb, pv, "downloadclient?forceSave=true", "POST", e)
    print("  + qBittorrent download client" if r else "  ! download client failed")
else:
    print("  qBittorrent download client already present")

# Applications: Sonarr + Radarr
def add_app(name, impl, contract, base_url, api_key, cats):
    if have(pb, pv, "applications", name):
        print(f"  application {name} already present"); return
    e = schema_entry(pb, pv, "applications/schema", impl)
    set_fields(e, {"prowlarrUrl": "http://prowlarr:9696", "baseUrl": base_url,
                   "apiKey": api_key, "syncCategories": cats})
    e.update({"name": name, "syncLevel": "fullSync"})
    r = call(pb, pv, "applications", "POST", e)
    print(f"  + application {name}" if r else f"  ! application {name} failed")

add_app("Sonarr", "Sonarr", "SonarrSettings", "http://sonarr:8989", SONARR[1],
        [5000,5010,5020,5030,5040,5045,5050,5090])
add_app("Radarr", "Radarr", "RadarrSettings", "http://radarr:7878", RADARR[1],
        [2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090])
if LIDARR[1]:
    add_app("Lidarr", "Lidarr", "LidarrSettings", "http://lidarr:8686", LIDARR[1],
            [3000,3010,3030,3040])

# A few reliable public indexers to start with (add/curate the rest in the UI)
WANT = {
    "thepiratebay":  False,
    "yts":           False,
    "eztv":          True,    # Cloudflare -> needs FlareSolverr
    # "1337x":       True,    # Cloudflare bans the PIA exit IP; add manually if a
    #                         # different PIA region works for you
}
app_profiles = call(pb, pv, "appprofile") or []
app_profile_id = app_profiles[0]["id"] if app_profiles else 1
sch = call(pb, pv, "indexer/schema") or []
by_def = {s.get("definitionName", "").lower(): s for s in sch}
existing_idx = {i["name"].lower() for i in call(pb, pv, "indexer") or []}
for defname, needs_fs in WANT.items():
    s = by_def.get(defname)
    if not s:
        print(f"  ? indexer '{defname}' not in schema, skipping"); continue
    if s["name"].lower() in existing_idx:
        print(f"  indexer {s['name']} already present"); continue
    s.setdefault("fields", [])
    s.update({"enable": True, "appProfileId": app_profile_id,
              "tags": [fs_tag] if needs_fs else []})
    r = call(pb, pv, "indexer?forceSave=true", "POST", s)
    print(f"  + indexer {s['name']}" + (" (via FlareSolverr)" if needs_fs else "")
          if r else f"  ! indexer {defname} failed (add it manually in the UI)")

print("\n== sync indexers to the apps ==")
r = call(pb, pv, "command", "POST", {"name": "ApplicationIndexerSync"})
print("  triggered ApplicationIndexerSync" if r else "  ! could not trigger sync")

print("""
Done. Verify:
  Prowlarr  http://192.168.1.64:9696  -> Settings > Apps : Sonarr + Radarr "OK"
                                       -> Indexers : green, test-passing
  Sonarr    http://192.168.1.64:8989  -> Settings > Indexers : populated from Prowlarr
                                       -> Settings > Download Clients : qBittorrent "Test" green
  Radarr    http://192.168.1.64:7878  -> same two checks
  Lidarr    http://192.168.1.64:8686  -> same two checks

Quality profiles are NOT set by this script. Sonarr + Radarr get theirs from
recyclarr/recyclarr.yml:
  docker compose run --rm recyclarr sync --preview   # dry run first
  docker compose run --rm recyclarr sync
Lidarr's profile is still a manual step in its UI (FLAC preferred, MP3-320
fallback, upgrade until FLAC).
""")
