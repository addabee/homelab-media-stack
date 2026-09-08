# Self-Hosted Media Stack

A production media server on a single Linux host: nine containerized services
behind a VPN killswitch, with automatic TLS, hardware-accelerated transcoding,
and hardlink-based library imports.

Runs 24/7 on consumer hardware — Ryzen 9 3900X, RTX 4070, 7.3 TB array. Two
services are reachable from the internet; the other seven deliberately are not.

**Stack:** Docker Compose · Caddy · Jellyfin · gluetun (OpenVPN) · qBittorrent ·
Sonarr · Radarr · Prowlarr · Bazarr · Jellyseerr · DuckDNS · Python · Bash · ufw

## Architecture

```
                          Internet
                              │
                      :80 :443│   ← the only forwarded ports
                              ▼
                ┌──────────────────────────────┐
                │  Caddy   (network_mode: host)│  Let's Encrypt, auto-renewed
                │  TLS termination + proxy     │
                └───────┬──────────────┬───────┘
                        │              │
                 jellyfin.*      requests.*
                        │              │
                        ▼              ▼
                 ┌───────────┐   ┌────────────┐
   RTX 4070 ───► │ Jellyfin  │   │ Jellyseerr │
   NVENC/CUDA    │  :8096    │   │   :5055    │
                 └─────┬─────┘   └──────┬─────┘
                       │                │
                       │                ▼
                       │   ┌──────────────────────────┐
                       │   │ Sonarr · Radarr          │  LAN only —
                       │   │ Prowlarr · Bazarr        │  never proxied
                       │   └────────────┬─────────────┘
                       │                │
                       │                ▼
                       │   ┌──────────────────────────────┐
                       │   │ gluetun — VPN killswitch     │
                       │   │   ├── qBittorrent            │  share gluetun's
                       │   │   └── FlareSolverr           │  network namespace
                       │   └────────────┬─────────────────┘
                       │                │
                       ▼                ▼
                ┌────────────────────────────────────────┐
                │  /mnt/calculon   (single filesystem)   │
                │  media/  ◄──── hardlinks ────  downloads/│
                └────────────────────────────────────────┘
```

## Design decisions

**Torrent traffic cannot leak.** qBittorrent and FlareSolverr have no network
stack of their own — they run in gluetun's namespace via `network_mode:
service:gluetun`. If the VPN drops, they lose connectivity entirely rather than
falling back to the home connection. There is no killswitch to misconfigure
because there is no alternate route.

**Imports are free.** `downloads/` and `media/` live on one filesystem, mounted
into every container at the same path (`/data`). Sonarr and Radarr import by
hardlink, so a completed download appears in the library instantly, seeds
without a second copy, and uses no extra disk. Splitting those two directories
across filesystems silently turns every import into a full copy.

**The public attack surface is two services, not nine.** Jellyfin and Jellyseerr
are proxied; the \*arr apps and qBittorrent stay LAN-only. They ship with weak or
absent authentication and have a rough CVE history, and a request portal already
covers what a remote user actually needs. Remote admin goes over Tailscale
instead of through the proxy.

**Forwarded ports sync themselves.** PIA rotates the forwarded port on every
reconnect, which would otherwise silently kill torrent connectivity. A mod
running inside the qBittorrent container watches gluetun's control API and
rewrites the listen port on change — no cron job, no separate container.

**Transcoding runs on the GPU.** The full CUDA decode → tone-map → encode
pipeline is verified against Jellyfin's bundled ffmpeg, with NVENC h264/hevc/av1
and a tmpfs transcode scratch to keep churn off the array.

## Services

| Piece | Where | Notes |
|---|---|---|
| Jellyfin | **native** (systemd), port `8096` | 10.11.11, not in this stack |
| gluetun | container | PIA OpenVPN + port forwarding, VPN gateway; control server on `:8000` is API-key protected |
| qBittorrent | container, via gluetun | Web UI `:8080`; listen port auto-synced to PIA's forwarded port by the GSP mod (runs inside this container) |
| Prowlarr | container | `:9696` — indexer manager |
| Sonarr | container | `:8989` — TV |
| Radarr | container | `:7878` — movies |
| Bazarr | container | `:6767` — subtitles |
| Jellyseerr | container | `:5055` — request portal |
| FlareSolverr | container, via gluetun | `:8191` — Cloudflare solver for Prowlarr |

## Directory layout

```
/mnt/calculon/
├── media/            # Jellyfin libraries (host jellyfin user reads these)
│   ├── movies/
│   ├── tv/
│   └── music/
├── downloads/
│   ├── incomplete/
│   └── complete/
└── media-stack/
    ├── docker-compose.yml
    ├── .env                     # PIA creds + GSP_GTN_API_KEY — chmod 600, do not share
    ├── install-docker.sh
    ├── install-jellyfin-plugins.sh
    └── appdata/
        ├── <service>/           # each container's /config
        └── gluetun/auth/config.toml   # control-server API key (matches GSP_GTN_API_KEY)
```

Inside the containers everything is mounted as `/data` (= `/mnt/calculon`), so
Sonarr/Radarr move downloads → library as **hardlinks** (instant, no copy, no
double disk usage). Never change the container path mappings without reading
the TRaSH-Guides "hardlinks" page.

## Bring-up order

### 1. Jellyfin plugins  (needs sudo)
```
sudo bash /mnt/calculon/media-stack/install-jellyfin-plugins.sh
```
Installs Playback Reporting, TMDb Box Sets, Intro Skipper, restarts Jellyfin.
Check **Dashboard → Plugins** — all three should be *Active*.

### 2. Docker  (needs sudo, one time)
```
sudo bash /mnt/calculon/media-stack/install-docker.sh
newgrp docker      # or log out/in
```

### 3. PIA credentials
Edit `/mnt/calculon/media-stack/.env` and set `PIA_USER` / `PIA_PASS`.
Leave `PIA_REGION` on a port-forwarding region (not US).

`.env` also ships a `GSP_GTN_API_KEY` (used by the port-sync mod, see step 6).
It must match `apikey` in `appdata/gluetun/auth/config.toml`. To rotate:
`openssl rand -hex 32` and paste the same value into both files, then
`docker compose up -d --force-recreate gluetun qbittorrent`.

### 4. Start the stack
```
cd /mnt/calculon/media-stack
docker compose up -d
docker compose logs -f gluetun        # wait for "You are running the latest version" + a forwarded port line
```

Confirm the VPN is actually carrying torrent traffic:
```
docker compose exec gluetun sh -c 'wget -qO- https://ipinfo.io/ip'   # should be a PIA IP, not your home IP
docker compose exec gluetun sh -c 'cat /tmp/gluetun/forwarded_port'  # the port PIA forwarded
```

### 5. First-run config (web UIs)

- **qBittorrent** `http://192.168.1.64:8080` — temp admin password is in
  `docker compose logs qbittorrent`. Log in, set a real password.
  - Options → Downloads: default save path `/data/downloads/complete`,
    keep incomplete in `/data/downloads/incomplete`.
  - Options → Connection: **untick** "Use random port" and disable UPnP.
    You do **not** need to set the listen port by hand — the GSP mod keeps it
    equal to PIA's `forwarded_port` (see step 6).
  - `WebUI\LocalHostAuth=false` is set in `appdata/qbittorrent/qBittorrent/
    qBittorrent.conf` so the port-sync mod can call the API over loopback
    without a password. LAN users still log in; the `172.28.0.0/24` whitelist
    still lets the *arr apps through without one.
- **Prowlarr** `:9696` — add indexers; add FlareSolverr as a tag/proxy at
  `http://gluetun:8191`; add qBittorrent download client at
  `http://gluetun:8080`. Then Settings → Apps: add Sonarr `http://sonarr:8989`
  and Radarr `http://radarr:7878` (paste each app's API key) so indexers sync.
- **Sonarr / Radarr** — Media Management → Root Folder `/data/media/tv` and
  `/data/media/movies`. Add qBittorrent at `http://gluetun:8080`.
- **Bazarr** — point at Sonarr `http://sonarr:8989` / Radarr `http://radarr:7878`.
- **Jellyseerr** `:5055` — connect to Jellyfin at `http://192.168.1.64:8096`,
  then to Sonarr/Radarr by container name.
- **Jellyfin** — add libraries pointing at `/mnt/calculon/media/movies`,
  `/mnt/calculon/media/tv`, `/mnt/calculon/media/music`.

### 6. Forwarded-port auto-sync (already set up)
PIA rotates the forwarded port on every reconnect. Keeping qBittorrent's listen
port in step with it is handled by the **GSP mod**
(`ghcr.io/t-anc/gsp-qbittorent-gluetun-sync-port-mod`), pulled in via
`DOCKER_MODS` on the `qbittorrent` service — no separate container.

How it works:
- Runs inside the qbittorrent container, which shares gluetun's network
  namespace, so it reaches the gluetun control server at `localhost:8000` and
  the qBittorrent Web UI at `localhost:8080`.
- Authenticates to gluetun with `GSP_GTN_API_KEY` (must match
  `appdata/gluetun/auth/config.toml`); to qBittorrent it needs no credential
  because `WebUI\LocalHostAuth=false`.
- Polls for a change and writes the new port into qBittorrent automatically.

Check it:
```
docker logs qbittorrent 2>&1 | grep GSP
docker exec gluetun sh -c 'cat /tmp/gluetun/forwarded_port'
docker exec qbittorrent sh -c 'grep -a "^Session.Port=" /config/qBittorrent/qBittorrent.conf'
```
The last two should show the same number.

The old standalone `gluetun-qb-portsync` service (image
`ghcr.io/mag37/gluetun-qbit-port-sync`) is gone — that image is no longer
published. `QBITTORRENT_PASSWORD` in `.env` is unused by this setup.

## Remote access (DuckDNS + Caddy)

Public URLs, real HTTPS, no VPN client needed on the viewer's device:

| URL | Goes to |
|---|---|
| `https://jellyfin.${DUCKDNS_SUBDOMAIN}.duckdns.org` | Jellyfin (native, `:8096`) |
| `https://requests.${DUCKDNS_SUBDOMAIN}.duckdns.org` | Jellyseerr (`:5055`) |

Nothing else is published. Sonarr/Radarr/Prowlarr/Bazarr/qBittorrent stay
LAN-only — they ship with weak or no auth and a rough CVE history, and a
request portal already covers what a remote user actually needs.

How it hangs together:

- **duckdns** container pings DuckDNS every 5 min so `${DUCKDNS_SUBDOMAIN}.duckdns.org` tracks
  your public IP. This needs to be a real routable address — inbound
  forwarding cannot work behind carrier-grade NAT (CGNAT), so check with your
  ISP first if you are unsure.
- DuckDNS **wildcards**: `anything.${DUCKDNS_SUBDOMAIN}.duckdns.org` resolves to that same
  record, which is why two hostnames need only one DuckDNS entry.
- **caddy** container runs `network_mode: host`, owns `:80`/`:443`, fetches and
  auto-renews Let's Encrypt certs, and reverse-proxies to `127.0.0.1:8096` /
  `127.0.0.1:5055`. Config: [`caddy/Caddyfile`](caddy/Caddyfile).

### Setup

1. **DuckDNS** — already done. `.env` holds `DUCKDNS_SUBDOMAIN=<your-subdomain>` plus
   the token, verified against the API (`OK`), and `${DUCKDNS_SUBDOMAIN}.duckdns.org` —
   along with any `*.${DUCKDNS_SUBDOMAIN}.duckdns.org` — resolves to this house.
   To rotate the token later, get a new one at <https://www.duckdns.org> and
   replace `DUCKDNS_TOKEN` in `.env`.

2. **Open the host firewall.** `ufw` is active on this box, and because Caddy
   runs with `network_mode: host` it binds the host stack directly — so unlike
   the other containers (whose published ports bypass ufw via Docker's iptables
   chains) Caddy *is* subject to ufw. Without this the router forward will look
   correct and still fail:
   ```
   sudo ufw allow 80/tcp   comment 'caddy http -> https redirect + ACME'
   sudo ufw allow 443/tcp  comment 'caddy https'
   sudo ufw status numbered
   ```

3. **Forward TCP 80 + 443 on the gateway.**

   The gateway here is a **CommScope BGW620-700** (AT&T fiber, firmware 5.39.7)
   at <http://192.168.1.254>. It does not have a plain "port forwarding" form —
   AT&T calls it *NAT/Gaming*, and it works in two stages: first you define a
   **custom service** (the port rule), then you **assign that service to a
   device**. Doing only the first stage is the usual reason this appears not to
   work.

   This host is already known to the gateway as:

   | | |
   |---|---|
   | Name | `<hostname>` |
   | IPv4 | `192.168.1.64` |
   | MAC | `<host-MAC>` |
   | Link | Ethernet LAN-1, 1000 Mbps |
   | Allocation | `dhcp` ← pin this, see step 3d |

   **3a. Sign in.** Go to <http://192.168.1.254> → **Firewall** → **NAT/Gaming**.
   It will ask for the **Device Access Code** — a 12-character code on the
   sticker on the side/bottom of the gateway. That is *not* the Wi-Fi password.

   **3b. Create two custom services.** On the NAT/Gaming page choose
   **Custom Services** (or *Add a new user-defined application*), and add these
   one at a time:

   | Field | First entry | Second entry |
   |---|---|---|
   | Service Name | `Caddy-HTTP` | `Caddy-HTTPS` |
   | Global Port Range | `80` to `80` | `443` to `443` |
   | Base Host Port | `80` | `443` |
   | Protocol | `TCP` | `TCP` |
   | Protocol Timeout | leave default | leave default |

   Global port = what the internet connects to; base host port = what it lands
   on here. Same number both sides, so no translation.

   **3c. Assign both services to this machine.** Back on **NAT/Gaming**, in the
   *Needed by Device* dropdown pick **`<hostname>` (192.168.1.64)**, select
   `Caddy-HTTP` from the service list, click **Add**; repeat for `Caddy-HTTPS`.
   Both should then be listed in the hosted-applications table against that
   device. Save/apply — the gateway may drop connections for a few seconds.

   **3d. Pin the address.** The gateway currently hands this host a plain DHCP
   lease. Under **Home Network → IP Allocation**, find MAC `<host-MAC>`
   and set it to a fixed `192.168.1.64` so the forwards can't end up aimed at a
   different device after a reboot.

   **Three settings that must stay as they are:**

   - **Device → Remote Access: off.** If AT&T remote management is enabled the
     gateway keeps WAN 443 for itself and your 443 forward silently loses.
   - **Firewall → IP Passthrough: off** (currently off). Turning it on hands the
     public IP to one device and bypasses NAT entirely.
   - **NAT Default Server / DMZ: off** (currently off). It is *not* a shortcut
     for this — it would expose every port on this host, including Sonarr
     `:8989`, Radarr `:7878`, Prowlarr `:9696`, Bazarr `:6767` and qBittorrent
     `:8080`. Those ports are published by Docker, which writes its own iptables
     rules *ahead of* ufw, so ufw would not save you. Forward 80 and 443 only.

4. **Start it**
   ```
   cd /mnt/calculon/media-stack
   docker compose up -d duckdns caddy
   docker compose logs -f caddy      # want "certificate obtained successfully"
   ```

5. **Tell Jellyfin it's behind a proxy** — Dashboard → Networking → *Known
   proxies* = `127.0.0.1`, then `sudo systemctl restart jellyfin`. **Done.**
   Without it Jellyfin attributes every remote session to localhost, which
   breaks failed-login tracking and any IP-based rule.

   Lands in `/etc/jellyfin/network.xml` as:
   ```xml
   <KnownProxies>
     <string>127.0.0.1</string>
   </KnownProxies>
   ```

   Verify it is actually honouring the header — the logged IP should be the
   caller, *not* `127.0.0.1`:
   ```
   curl -s -o /dev/null -X POST -H 'Content-Type: application/json' \
     -H 'Authorization: MediaBrowser Client="p", Device="p", DeviceId="p", Version="1"' \
     -d '{"Username":"__proxytest__","Pw":"x"}' \
     https://jellyfin.${DUCKDNS_SUBDOMAIN}.duckdns.org/Users/AuthenticateByName
   grep -a __proxytest__ /var/log/jellyfin/jellyfin$(date +%Y%m%d)*.log | tail -1
   ```
   (Testing from inside the LAN logs `192.168.1.254` — the gateway, because
   NAT loopback source-NATs the request. That still proves the chain works.)

   There is no UPnP / "automatic port mapping" setting to disable: Jellyfin
   removed it in 10.9, and this host runs 10.11.11.

6. **Jellyseerr** — Settings → General → Application URL:
   `https://requests.${DUCKDNS_SUBDOMAIN}.duckdns.org`

7. **Verify**
   ```
   bash /mnt/calculon/media-stack/check-remote-access.sh
   ```
   Checks DNS, cert issuance, both URLs end to end, and that the admin ports are
   *not* answering from outside. Test the URLs from cell data too — some
   gateways don't do NAT loopback, so they can look broken from inside the LAN
   while working fine from the internet.

### Keeping it safe

- Jellyfin is the front door now: every account needs a real password, and
  turn off any guest/auto-login. Dashboard → Users.
- Watch for failed logins: Dashboard → Notifications, or the Playback Reporting
  plugin already installed.
- To reach the *arr apps from outside, add Tailscale (`sudo tailscale up`)
  rather than proxying them — it needs no port forwards and no public exposure.
- `docker compose pull && docker compose up -d` picks up Caddy/Jellyfin security
  fixes; worth doing monthly now that something is internet-facing.

## Transcoding: software by choice

Jellyfin on this host transcodes in **software only** — `HardwareAccelerationType`
is `none`, `EncodingThreadCount` is capped at 8 of 24 threads.

That is a deliberate trade, not a missing feature. The RTX 4070 is dedicated to
paid GPU compute rentals, and a GPU cannot be meaningfully shared between a
tenant's CUDA workload and Jellyfin's NVENC sessions: whoever gets there second
fails. Reserving the card entirely keeps it sellable and keeps playback
predictable. The thread cap exists for the same reason — CPU cores are rented
alongside the GPU, so an unbounded transcode would degrade a paying workload.

Two profiles live side by side, and `apply-jellyfin-gpu.sh` still switches
between them:

| Profile | Used when |
|---|---|
| `jellyfin-encoding.cpu.xml` | **current** — x264 `veryfast`, no hwaccel, 8 threads |
| `jellyfin-encoding.optimized.xml` | rollback if GPU renting ever stops — NVENC h264/hevc/av1, enhanced NVDEC, bt2390 CUDA tone-mapping |

The GPU path is fully working and verified against
`/usr/lib/jellyfin-ffmpeg/ffmpeg` (driver 595-server open, plus
`libnvidia-encode/decode-595-server`); it is simply not in use.

### The arbiter, and why it was retired

`jellyfin-gpu-arbiter.sh` automates the middle ground: it polls for GPU
tenancy — primarily any container holding a `DeviceRequests` GPU claim, with a
foreign-CUDA-process check as a second signal — and swaps Jellyfin between the
two profiles, debouncing across two polls so a momentary blip cannot trigger a
switch. It was built, tested in both directions, and then **retired**: every
switch restarts Jellyfin, which drops any stream in progress. Trading a
predictable software transcode for an unpredictable mid-episode disconnect was
the wrong way round. It is kept, disabled, for anyone whose GPU is only
occasionally rented.

Install it with `jellyfin-gpu-arbiter-install.sh` if that trade suits you better.

> One gotcha worth recording: Jellyfin **rewrites `encoding.xml` on startup**
> and silently discards values it cannot parse — a hand-written
> `<EncoderPreset>veryfast</EncoderPreset>` came back as `xsi:nil`. Derive new
> profiles from a file Jellyfin itself has written, and always re-read the file
> after restarting to confirm your settings actually persisted.

## Notes / TODO

- `.env` contains a live credential. It is `chmod 600`. Don't copy it into a
  git repo or a shared location.
- Update everything: `cd /mnt/calculon/media-stack && docker compose pull && docker compose up -d`.
