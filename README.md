# Self-Hosted Media Stack

A production media server on a single Linux host: nine containerized services
behind a VPN killswitch, with automatic TLS, hardware-accelerated transcoding,
and hardlink-based library imports.

Runs 24/7 on consumer hardware — Ryzen 9 3900X, RTX 4070, 7.3 TB array. Two
services are reachable from the internet; the other seven deliberately are not.

**Stack:** Docker Compose · Caddy · Jellyfin · gluetun (OpenVPN) · qBittorrent ·
Sonarr · Radarr · Prowlarr · Bazarr · Jellyseerr · DuckDNS · WireGuard · Python ·
Bash · ufw

## Architecture

```
                          Internet
                              │
              :80 :443 tcp    │    :51820 udp      ← the only forwarded ports
                    ┌─────────┴─────────┐
                    ▼                   ▼
  ┌──────────────────────────────┐  ┌──────────────────────┐
  │  Caddy   (network_mode: host)│  │ WireGuard (native)   │  admin only:
  │  TLS termination + proxy     │  │ wg0  10.13.13.0/24   │  tunnel → LAN
  └───────┬──────────────┬───────┘  └──────────┬───────────┘
          │              │                     │
   jellyfin.*      requests.*                  │
          │              │                     │
          ▼              ▼                     │
   ┌───────────┐   ┌────────────┐              │
   │ Jellyfin  │◄──│ Jellyseerr │              │
   │  :8096    │   │   :5055    │              │
   └─────┬─────┘   └──────┬─────┘              │
   ▲     │                │                    │
RTX 4070 │                ▼                    ▼
NVENC    │   ┌──────────────────────────────────────────┐
         │   │ Sonarr · Radarr · Prowlarr · Bazarr      │  LAN + tunnel only —
         │   │ qBittorrent UI                           │  never proxied
         │   └────────────┬─────────────────────────────┘
         │                │
         │                ▼
         │   ┌──────────────────────────────┐
         │   │ gluetun — VPN killswitch     │
         │   │   ├── qBittorrent            │  share gluetun's
         │   │   └── FlareSolverr           │  network namespace
         │   └────────────┬─────────────────┘
         │                │
         ▼                ▼
  ┌──────────────────────────────────────────┐
  │  /mnt/calculon   (single filesystem)     │
  │  media/  ◄──── hardlinks ────  downloads/│
  └──────────────────────────────────────────┘
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
covers what a remote user actually needs. Remote admin goes over a WireGuard
tunnel instead of through the proxy — it authenticates by key before it will
even answer a packet, and it runs natively so it still works when Docker is
down (see [Remote admin](#remote-admin-wireguard)).

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
| WireGuard | **native** (`wg-quick@wg0`), UDP `51820` | admin tunnel to the LAN; not in this stack |
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
- To reach the *arr apps from outside, use the [WireGuard tunnel](#remote-admin-wireguard)
  rather than proxying them.
- Container images update themselves weekly (see
  [Automatic updates](#automatic-updates)), which picks up Caddy security fixes.
  Jellyfin is native, so it updates with `apt`.

## Remote admin (WireGuard)

Everything Caddy does *not* publish — Sonarr, Radarr, Prowlarr, Bazarr, the
qBittorrent UI, SSH to the host — is reached from outside over a WireGuard
tunnel. A connected device gets an address on `10.13.13.0/24` and sees
`192.168.1.0/24` as if it were on the home Wi‑Fi.

Why WireGuard, and why native:

- **Nothing to attack.** The server answers only packets that carry a valid
  handshake for a known key; everything else is dropped silently. A port scan
  sees a closed port. That is a much smaller surface than any web login.
- **Runs on the host, not in a container.** This is the tunnel you use to fix
  Docker when Docker is broken. The kernel module ships with Ubuntu; the
  install adds only `wireguard-tools`, one config file and a systemd unit.
- **Split tunnel by default.** Only LAN traffic rides the VPN; the phone's
  normal connection carries everything else, so there's no battery or
  bandwidth cost to leaving it on. `--full` peers route *everything* through
  home for hostile Wi‑Fi.
- **No Tailscale.** It would be easier, but it puts a third party's control
  plane in the auth path. Plain WireGuard is two files and no account.

### Setup (once)

```
sudo bash /mnt/calculon/media-stack/wireguard-install.sh
```

Installs the tools, generates the server key into `/etc/wireguard/wg0.conf`,
persists `ip_forward`, opens ufw (`51820/udp` in; `wg0` trusted in and
forwarded like the LAN), and enables `wg-quick@wg0`. Safe to re-run.

Then forward **UDP 51820** on the gateway, same two-stage NAT/Gaming dance as
[step 3 above](#setup): custom service `WireGuard`, global port `51820`–`51820`,
base host port `51820`, protocol **UDP**, assigned to this host (`192.168.1.64`).

### Adding a device

```
sudo ./wg-peer.sh add phone            # split tunnel: LAN only
sudo ./wg-peer.sh add laptop --full    # everything via home
```

Prints a QR code (WireGuard app → **+** → *Scan from QR code*) and the same
config as a file for desktop clients. `show <name>` re-prints it, `list` shows
who exists, `status` shows who is connected and when they last handshook,
`remove <name>` revokes a device — its key is destroyed and the change is live
immediately, no restart.

Client private keys live in `/etc/wireguard/peers/` (root-only, `0600`). One
peer per device: a key can't be connected from two places at once, and
revoking one device shouldn't take out the others.

Once connected, the admin apps are at their LAN addresses:
`http://192.168.1.64:8989` (Sonarr), `:7878` (Radarr), `:9696` (Prowlarr),
`:6767` (Bazarr), `:8080` (qBittorrent), and `ssh 192.168.1.64`.

### How it hangs together

- `wg0.conf` `[Interface]` has the server key and a `PostUp` that
  MASQUERADEs `10.13.13.0/24` out of `enp5s0`, because LAN devices (and the
  gateway) have no route back to the tunnel subnet. Docker containers behind
  published ports don't need it — the host routes replies straight back.
- Each `[Peer]` block is tagged `# peer: <name>` so `wg-peer.sh` can find it;
  changes are applied with `wg syncconf` so other peers stay up.
- ufw: `51820/udp` open to the world (safe, see above); `allow in on wg0` so
  tunnel clients reach native services on the host; `route allow in on wg0`
  so they're forwarded to containers, the LAN and (for `--full`) the internet.
- Endpoint is `${DUCKDNS_SUBDOMAIN}.duckdns.org:51820` — the same dynamic DNS
  record Caddy uses, read from `.env` at peer-creation time.

Check it: `bash check-remote-access.sh` (step 9), or `sudo ./wg-peer.sh status`
after connecting a phone from cell data — a handshake in the last couple of
minutes means the port forward and everything behind it works.

## Transcoding

Jellyfin uses **NVENC hardware transcoding** on the RTX 4070 — the full CUDA
decode → tone-map → encode pipeline, verified against
`/usr/lib/jellyfin-ffmpeg/ffmpeg` (driver 595-server open, plus
`libnvidia-encode/decode-595-server`). Apply it with:

```
sudo bash apply-jellyfin-gpu.sh          # --restore to roll back
```

That installs `jellyfin-encoding.optimized.xml`, enables enhanced NVDEC,
HEVC + AV1 output, bt2390 CUDA tone-mapping, transcode throttling and segment
deletion, and mounts `/var/cache/jellyfin/transcodes` as an 8 GB tmpfs.

### Sharing the GPU with other workloads

Jellyfin's NVENC sessions can run alongside another CUDA workload: encode and
decode use dedicated NVENC/NVDEC engines, so the two coexist as long as there is
VRAM to spare. What they do contend for is the CUDA cores, which Jellyfin's
tone-mapping and scaling filters also run on, and memory — a tenant that claims
most of the VRAM, or the whole card, will make transcodes fail to start. Two
pieces exist for hosts that need to give the card up entirely sometimes:

| File | Purpose |
|---|---|
| `jellyfin-encoding.cpu.xml` | Software profile — x264 `veryfast`, no hwaccel, thread-capped |
| `jellyfin-gpu-arbiter.sh` | Polls for GPU tenancy and swaps profiles automatically |

The arbiter detects a tenant primarily by any container holding a
`DeviceRequests` GPU claim, with a foreign-CUDA-process check as a second
signal, and debounces across two polls so a momentary blip cannot trigger a
switch. It is **disabled by default**: every switch restarts Jellyfin, dropping
streams in progress, so it is only worth running if the card is genuinely
contended. Install with `jellyfin-gpu-arbiter-install.sh`.

The CPU profile caps `EncodingThreadCount` rather than leaving it unbounded, so
a transcode cannot starve whatever else shares the machine.

> One gotcha worth recording: Jellyfin **rewrites `encoding.xml` on startup**
> and silently discards values it cannot parse — a hand-written
> `<EncoderPreset>veryfast</EncoderPreset>` came back as `xsi:nil`. Derive new
> profiles from a file Jellyfin itself has written, and always re-read the file
> after restarting to confirm your settings actually persisted.

## Storj node monitoring

The host also runs a Storj storage node, sharing the array with the media
libraries. `storj-monitor.py` watches it and pushes alerts via
[ntfy](https://ntfy.sh):

| Check | Why it matters |
|---|---|
| Storage array mounted | The array is mounted `nofail`, so the host boots without it — the node would then fail every audit |
| Array free space | A full disk fails audits |
| Dashboard reachable | Container stopped |
| QUIC status | Catches a silently broken port forward, e.g. after a DHCP lease moves |
| Satellite contact age | No ping in 20 min means unreachable from the internet |
| Allocation full | |
| Disqualified / suspended | Suspension is the warning before the permanent one |
| Audit / suspension / online scores | Below threshold |
| Node version | Out of date |

Two design decisions worth calling out:

**It alerts only on state changes.** One message when something breaks, one when
it clears. A monitor that re-reports the same problem every 15 minutes becomes
noise you learn to ignore, which is the same as having no monitor.

**It lives on the root filesystem, not the array.** Putting it beside the node's
data would mean it disappears exactly when the array fails to mount — unable to
report the one failure most likely to disqualify the node.

```
bash storj-monitor-install.sh    # no root needed
```

The installer generates a random ntfy topic (the topic name is the only access
control, so it must be unguessable) and adds a 15-minute cron entry. Thresholds
and the alert channel live in `~/.config/storj-monitor.conf` — set `NOTIFY_CMD`
there to route alerts to a Discord/Slack webhook or anything else instead.

## Automatic updates

`update-stack.sh` pulls newer images and recreates only the containers whose
image changed. A cron entry runs it **Sundays at 04:30**, logging to
`~/.local/state/update-stack.log`. Install the entry with
`./update-stack.sh --install`; preview a run with `./update-stack.sh --dry-run`.

- Each updated container restarts for a few seconds. Jellyfin runs natively, so
  playback on the LAN is unaffected; remote streams drop briefly if Caddy updates.
- If gluetun is replaced, qBittorrent and FlareSolverr would be left attached to
  the old container's network namespace, with no network at all. The script
  checks for that and recreates them onto the new one.
- Superseded images are pruned after each run.
- Only services in `docker-compose.yml` are touched. Storj's `storagenode`
  container updates its own binary internally.

## Notes / TODO

- `.env` contains a live credential. It is `chmod 600`. Don't copy it into a
  git repo or a shared location.
- Update everything now, without waiting for Sunday: `./update-stack.sh`.
