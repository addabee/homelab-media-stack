#!/usr/bin/env python3
"""
Remove the orphaned Jellyfin library rows left behind by an earlier library that
pointed at /mnt/calculon/downloads/complete/{tv,movies}. Those rows still attach
to the real series by provider id, so Batman/Futurama episodes appear twice.

Jellyfin must be STOPPED while this runs. Intended invocation:

    sudo systemctl stop jellyfin
    sudo -u jellyfin python3 /mnt/calculon/media-stack/jf_orphan_clean.py
    sudo systemctl start jellyfin

Only touches rows whose Path is under /mnt/calculon/downloads/ plus the two dead
folder objects. Backs the database up first. ON DELETE CASCADE handles the child
tables; the few tables without an FK are swept for now-dangling ItemIds.
"""
import sqlite3, shutil, time, sys, os

DB = "/var/lib/jellyfin/data/jellyfin.db"
DEAD_FOLDERS = ("5AD6CB81-CC57-9206-4493-CDFDFEF1E176",   # /mnt/calculon/downloads/complete/tv
                "FE93C141-07C0-AF17-07E5-E4C274E66B5D")   # /mnt/calculon/downloads/complete/movies

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

before = db.execute("SELECT COUNT(*) FROM BaseItems WHERE Path LIKE '/mnt/calculon/downloads/%'").fetchone()[0]
print(f"orphan items under /downloads path: {before}")

n1 = db.execute("DELETE FROM BaseItems WHERE Path LIKE '/mnt/calculon/downloads/%'").rowcount
n2 = db.execute("DELETE FROM BaseItems WHERE Id IN (?,?)", DEAD_FOLDERS).rowcount
print(f"deleted from BaseItems: {n1} items + {n2} dead folders (child rows cascade)")

# tables that reference items but have no FK / cascade
for t in ("MediaSegments", "TrickplayInfos", "AttachmentStreamInfos",
          "BaseItemTrailerTypes", "ItemDisplayPreferences",
          "CustomItemDisplayPreferences", "DisplayPreferences", "ActivityLogs"):
    try:
        c = db.execute(
            f"DELETE FROM {t} WHERE ItemId IS NOT NULL "
            f"AND ItemId NOT IN (SELECT Id FROM BaseItems)").rowcount
        if c:
            print(f"  swept {t}: {c}")
    except sqlite3.OperationalError as e:
        print(f"  skip {t}: {e}")

db.commit()
db.execute("VACUUM")

after = db.execute("SELECT COUNT(*) FROM BaseItems WHERE Path LIKE '/mnt/calculon/downloads/%'").fetchone()[0]
print(f"\nremaining /downloads items: {after}")
for r in db.execute("SELECT COALESCE(SeriesName,'(none)'), COUNT(*) "
                    "FROM BaseItems WHERE Type LIKE '%Episode%' GROUP BY SeriesName ORDER BY 1"):
    print(f"  {r[0]:26} {r[1]} episodes")
db.close()
print("\nOK — start jellyfin now.")
