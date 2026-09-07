#!/usr/bin/env python3
"""
Delete the corrupted Futurama series/season/episode rows so a rescan rebuilds
them from the files in /mnt/calculon/media/tv/Futurama (1999)/.

The Futurama series row carries an empty GUID that makes Jellyfin throw
'Guid can't be empty' on load, so it can never attach its episodes.

Jellyfin must be STOPPED. Intended invocation:

    sudo systemctl stop jellyfin
    sudo -u jellyfin python3 /mnt/calculon/media-stack/jf_fix_futurama.py
    sudo systemctl start jellyfin
"""
import sqlite3, shutil, time, os, sys

DB = "/var/lib/jellyfin/data/jellyfin.db"
if not os.access(DB, os.W_OK):
    sys.exit(f"cannot write {DB} — run as the jellyfin user (sudo -u jellyfin ...)")

bak = f"{DB}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
for suf in ("", "-wal", "-shm"):
    if os.path.exists(DB + suf):
        shutil.copy2(DB + suf, bak + suf)
print(f"backup: {bak}")

db = sqlite3.connect(DB)
db.execute("PRAGMA foreign_keys = ON")
db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

ids = {r[0] for r in db.execute(
    "SELECT Id FROM BaseItems WHERE Path LIKE '/mnt/calculon/media/tv/Futurama%'")}
ids |= {r[0] for r in db.execute(
    "SELECT Id FROM BaseItems WHERE Type LIKE '%Series%' AND Name='Futurama'")}
print(f"removing {len(ids)} Futurama rows")

ph = ",".join("?" * len(ids)); t = tuple(ids)
n = db.execute(f"DELETE FROM BaseItems WHERE Id IN ({ph})", t).rowcount
for tbl in ("MediaSegments", "TrickplayInfos", "AttachmentStreamInfos",
            "BaseItemTrailerTypes", "ItemDisplayPreferences",
            "CustomItemDisplayPreferences", "DisplayPreferences"):
    try:
        db.execute(f"DELETE FROM {tbl} WHERE ItemId NOT IN (SELECT Id FROM BaseItems)")
    except sqlite3.OperationalError:
        pass
db.commit()
db.execute("VACUUM")

left = db.execute("SELECT COUNT(*) FROM BaseItems WHERE Path LIKE '%Futurama%'").fetchone()[0]
print(f"deleted {n} rows; remaining Futurama rows: {left}")
db.close()
print("\nStart jellyfin, then run a Shows library scan — Futurama will rebuild from disk.")
