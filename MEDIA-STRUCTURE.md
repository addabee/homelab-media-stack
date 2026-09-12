# Media structure — calculon-media

Everything is on one filesystem (`/mnt/calculon`), mounted into the containers
as `/data`, so Sonarr/Radarr import from `downloads/` into `media/` as
**hardlinks** — instant, no copy, no extra disk use. Never break the shared
`/data` mount or move `downloads` and `media` onto different filesystems.

```
/mnt/calculon/
├── media/                         <- Jellyfin libraries point here
│   ├── movies/                    Jellyfin library type: Movies
│   ├── tv/                        Jellyfin library type: Shows
│   └── music/                     Jellyfin library type: Music
└── downloads/
    ├── incomplete/                in-progress torrents
    └── complete/
        ├── movies/                qB category: radarr
        ├── tv/                    qB category: sonarr
        ├── music/                 qB category: music
        ├── books/                 qB category: books
        └── manual/                qB categories: manual, prowlarr
```

Host paths ↔ container paths:

| Host | In qB / Sonarr / Radarr |
|---|---|
| `/mnt/calculon/media/movies` | `/data/media/movies` |
| `/mnt/calculon/media/tv` | `/data/media/tv` |
| `/mnt/calculon/media/music` | `/data/media/music` |
| `/mnt/calculon/downloads` | `/data/downloads` |

---

## Jellyfin naming — Movies

One folder per movie, folder and file both `Title (Year)`.
<https://jellyfin.org/docs/general/server/media/movies/>

```
media/movies/
├── Blade Runner 2049 (2017)/
│   └── Blade Runner 2049 (2017).mkv
├── Dune (2021)/
│   ├── Dune (2021) - Bluray-2160p.mkv          # optional: [quality/edition] tag
│   └── Dune (2021) - Theatrical.mkv            # multiple versions live side by side
└── Parasite (2019)/
    ├── Parasite (2019).mkv
    └── Parasite (2019).en.srt                  # external subs: <name>.<lang>.srt
```

- Add the TMDb/IMDb id only if scans mismatch: `Dune (2021) [tmdbid-438631]`.
- Extras: put in a subfolder named `trailers/`, `extras/`, `behind the scenes/`,
  `deleted scenes/`, `interviews/`, `featurettes/`, `shorts/`, `scenes/`, or
  suffix the file `- trailer.mkv`.

## Jellyfin naming — TV

`Series (Year)/Season NN/Series (Year) SNNENN.ext`. Specials go in `Season 00`.
<https://jellyfin.org/docs/general/server/media/shows/>

```
media/tv/
└── Severance (2022)/
    ├── Season 01/
    │   ├── Severance (2022) S01E01.mkv
    │   ├── Severance (2022) S01E02.mkv
    │   └── Severance (2022) S01E01.en.srt
    ├── Season 02/
    │   └── Severance (2022) S02E01.mkv
    └── Season 00/
        └── Severance (2022) S00E01.mkv          # specials
```

- Multi-episode files: `... S01E01-E02.mkv`.
- Date-based shows: `Series (Year) SNNE01.ext` still works, or
  `Series (Year) - 2024-01-15.ext`.

## Jellyfin naming — Music

`Artist/Album (Year)/NN - Track.ext`, tags matter more than filenames.
<https://jellyfin.org/docs/general/server/media/music/>

```
media/music/
└── Radiohead/
    └── In Rainbows (2007)/
        ├── 01 - 15 Step.flac
        └── folder.jpg                           # album art
```

---

## Sonarr / Radarr settings that produce the names above

**Radarr → Settings → Media Management**
- Rename Movies: yes
- Standard Movie Format:
  `{Movie CleanTitle} ({Release Year}) {[Custom Formats]}{[Quality Full]}`
- Movie Folder Format: `{Movie CleanTitle} ({Release Year})`
- Root Folder: `/data/media/movies`

**Sonarr → Settings → Media Management**
- Rename Episodes: yes
- Standard Episode Format:
  `{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} {[Custom Formats]}{[Quality Full]}`
- Season Folder Format: `Season {season:00}`
- Series Folder Format: `{Series TitleYear}`
- Root Folder: `/data/media/tv`

**Quality profiles are NOT set here.** They live in
[`recyclarr/recyclarr.yml`](recyclarr/recyclarr.yml) and are pushed in daily by
the `recyclarr` container, which overwrites UI edits:

| App | Profile | Policy |
|---|---|---|
| Sonarr | `WEB-1080p` (TRaSH) | 1080p only, no 4K tier |
| Radarr | `Movies (4K preferred)` (hand-built) | 2160p preferred, 1080p fallback, upgraded in place; `Remux-2160p` excluded |
| Lidarr | set in the UI | FLAC preferred, MP3-320 fallback |

**Both → Settings → Download Clients → qBittorrent**
- Host `gluetun`, Port `8080`
- Category: `radarr` (Radarr) / `sonarr` (Sonarr) / `music` (Lidarr)
- Leave "Remove completed" on so hardlinked torrents are cleaned up after import.

**Jellyfin → Dashboard → Libraries → Add Media Library**
- Movies  → folder `/mnt/calculon/media/movies`
- Shows   → folder `/mnt/calculon/media/tv`
- Music   → folder `/mnt/calculon/media/music`
