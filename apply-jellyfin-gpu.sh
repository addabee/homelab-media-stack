#!/usr/bin/env bash
# apply-jellyfin-gpu.sh — point native Jellyfin at the RTX 4070 and apply an
# optimized transcoding profile. Idempotent. Run as root:
#
#   sudo bash /mnt/calculon/media-stack/apply-jellyfin-gpu.sh
#
# Flags:
#   --no-tmpfs     skip putting the transcode scratch dir on a RAM disk
#   --tmpfs-size N size of that RAM disk (default 8G)
#   --restore      put back the most recent encoding.xml backup and restart
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPT_XML="$SRC_DIR/jellyfin-encoding.optimized.xml"
CONF="/etc/jellyfin/encoding.xml"
TRANSCODE_DIR="/var/cache/jellyfin/transcodes"
FF="/usr/lib/jellyfin-ffmpeg/ffmpeg"
TMPFS=1
TMPFS_SIZE="8G"
RESTORE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-tmpfs) TMPFS=0 ;;
    --tmpfs-size) TMPFS_SIZE="$2"; shift ;;
    --restore) RESTORE=1 ;;
    *) echo "unknown flag: $1"; exit 2 ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || { echo "run me as root (sudo)"; exit 1; }

if [ "$RESTORE" -eq 1 ]; then
  latest="$(ls -1t "$CONF".bak.* 2>/dev/null | head -1 || true)"
  [ -n "$latest" ] || { echo "no backup found at $CONF.bak.*"; exit 1; }
  cp -a "$latest" "$CONF"
  chown jellyfin:jellyfin "$CONF"; chmod 644 "$CONF"
  systemctl restart jellyfin
  echo "restored $latest -> $CONF and restarted jellyfin"
  exit 0
fi

echo "==> Preflight"
command -v nvidia-smi >/dev/null || { echo "nvidia-smi missing — install nvidia-utils-595-server"; exit 1; }
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
lsmod | grep -q '^nvidia ' || { echo "nvidia kernel module not loaded"; exit 1; }
for lib in libnvidia-encode.so.1 libnvcuvid.so.1; do
  ldconfig -p | grep -q "$lib" || { echo "missing $lib — install libnvidia-encode-595-server / libnvidia-decode-595-server"; exit 1; }
done
echo -n "    NVENC probe (h264/hevc/av1): "
for c in h264_nvenc hevc_nvenc av1_nvenc; do
  "$FF" -hide_banner -loglevel error -f lavfi -i testsrc2=s=1280x720:r=30 -t 1 -c:v "$c" -f null - 2>/dev/null \
    && echo -n "$c ok  " || { echo "FAILED on $c"; exit 1; }
done; echo
[ -f "$OPT_XML" ] || { echo "optimized profile not found: $OPT_XML"; exit 1; }

echo "==> Backing up current encoding.xml"
ts="$(date +%Y%m%d-%H%M%S)"
if [ -f "$CONF" ]; then
  cp -a "$CONF" "$CONF.bak.$ts"
  echo "    $CONF.bak.$ts"
fi

echo "==> Installing optimized transcoding profile"
install -o jellyfin -g jellyfin -m 644 "$OPT_XML" "$CONF"
echo "    HardwareAccelerationType -> nvenc, NVENC encode + enhanced NVDEC, HEVC/AV1 out,"
echo "    CUDA tone-mapping (bt2390), throttling + segment deletion on, bwdif deinterlace."

echo "==> GPU driver persistence"
systemctl start nvidia-persistenced 2>/dev/null || true
systemctl is-active nvidia-persistenced >/dev/null && echo "    nvidia-persistenced active" || echo "    nvidia-persistenced not active (non-fatal)"

if [ "$TMPFS" -eq 1 ]; then
  echo "==> Transcode scratch on tmpfs ($TMPFS_SIZE)"
  install -d -o jellyfin -g jellyfin -m 755 "$TRANSCODE_DIR"
  line="tmpfs $TRANSCODE_DIR tmpfs defaults,size=$TMPFS_SIZE,uid=jellyfin,gid=jellyfin,mode=0755,noatime 0 0"
  if ! grep -qsE "^tmpfs[[:space:]]+$TRANSCODE_DIR[[:space:]]" /etc/fstab; then
    printf '\n# Jellyfin transcode scratch (RAM) — added by apply-jellyfin-gpu.sh\n%s\n' "$line" >> /etc/fstab
    echo "    added to /etc/fstab"
  fi
  systemctl daemon-reload
  mountpoint -q "$TRANSCODE_DIR" || mount "$TRANSCODE_DIR"
  findmnt "$TRANSCODE_DIR" || true
else
  echo "==> tmpfs step skipped (--no-tmpfs)"
fi

echo "==> Restarting Jellyfin"
systemctl restart jellyfin
for i in $(seq 1 30); do
  systemctl is-active --quiet jellyfin && break
  sleep 1
done
systemctl is-active --quiet jellyfin && echo "    jellyfin is up" || { echo "jellyfin failed to start"; journalctl -u jellyfin -n 40 --no-pager; exit 1; }

echo
echo "==> Done. Current GPU state:"
nvidia-smi --query-gpu=utilization.gpu,utilization.encoder,utilization.decoder,memory.used --format=csv
cat <<'EOF'

Next: play a file that forces a transcode (e.g. pick a lower quality in the web
player, or play something with burned-in/PGS subtitles) and watch:

    watch -n1 nvidia-smi

You should see an ffmpeg process on the GPU and non-zero "Enc"/"Dec". In the
Jellyfin dashboard, Playback → Transcoding will show "(hw)" next to the codecs.

Roll back any time:  sudo bash apply-jellyfin-gpu.sh --restore
EOF
