#!/usr/bin/env bash
# Switch native Jellyfin between NVENC and CPU transcoding depending on whether
# a Vast.ai renter currently holds the GPU.
#
# On this host Jellyfin is NATIVE and no legitimate container uses the GPU, so
# "a container requested the GPU" is a clean tenant signal. A foreign CUDA
# process is used as a second, independent check.
#
# Switching restarts Jellyfin, which drops active streams -- so it debounces
# and only acts on a sustained change, never a momentary blip.
set -uo pipefail

GPU_XML=/etc/jellyfin/encoding.gpu.xml
CPU_XML=/etc/jellyfin/encoding.cpu.xml
LIVE=/etc/jellyfin/encoding.xml
STATE_DIR=/var/lib/jellyfin-gpu-arbiter
CONF=/etc/jellyfin-gpu-arbiter.conf

CONFIRMATIONS=2        # consecutive agreeing polls before switching
NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC=""
[ -f "$CONF" ] && . "$CONF"

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
mkdir -p "$STATE_DIR"
MODE_F="$STATE_DIR/mode"; PEND_F="$STATE_DIR/pending"

notify() {
  [ -n "$NTFY_TOPIC" ] || return 0
  curl -s -m 15 -H "Title: $1" -H "Priority: default" -H "Tags: film_projector" \
       -d "$2" "${NTFY_SERVER%/}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
}

tenant_present() {
  # 1. Any running container that asked for GPU devices.
  if command -v docker >/dev/null 2>&1; then
    local c dr
    for c in $(docker ps -q 2>/dev/null); do
      dr="$(docker inspect -f '{{json .HostConfig.DeviceRequests}}' "$c" 2>/dev/null)"
      case "$dr" in ""|null|"[]") ;; *) return 0 ;; esac
    done
  fi
  # 2. Any CUDA process on the GPU that is not our own transcoder.
  local pid exe
  while read -r pid; do
    [ -n "$pid" ] || continue
    exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null)" || continue
    case "$exe" in
      /usr/lib/jellyfin-ffmpeg/*) ;;
      "") ;;
      *) return 0 ;;
    esac
  done < <(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)
  return 1
}

current_mode() {
  if [ -f "$MODE_F" ]; then cat "$MODE_F"
  elif grep -q "<HardwareAccelerationType>nvenc" "$LIVE" 2>/dev/null; then echo gpu
  else echo cpu; fi
}

switch_to() {
  local want="$1" src
  [ "$want" = cpu ] && src="$CPU_XML" || src="$GPU_XML"
  [ -f "$src" ] || { echo "missing profile $src" >&2; return 1; }
  install -o jellyfin -g jellyfin -m 644 "$src" "$LIVE"
  systemctl restart jellyfin
  local i
  for i in $(seq 1 30); do systemctl is-active --quiet jellyfin && break; sleep 1; done
  if systemctl is-active --quiet jellyfin; then
    echo "$want" > "$MODE_F"
    echo "switched Jellyfin transcoding -> ${want^^}"
    if [ "$want" = cpu ]; then
      notify "Jellyfin: CPU transcoding" \
        "A tenant took the GPU. Jellyfin switched to software transcoding (x264 veryfast). Expect higher CPU load and fewer simultaneous streams. Active streams were interrupted by the restart."
    else
      notify "Jellyfin: GPU transcoding restored" \
        "The GPU is free again. Jellyfin switched back to NVENC."
    fi
  else
    echo "jellyfin failed to start after switch to $want" >&2
    journalctl -u jellyfin -n 20 --no-pager >&2
    return 1
  fi
}

if tenant_present; then want=cpu; else want=gpu; fi
have="$(current_mode)"

if [ "$want" = "$have" ]; then
  rm -f "$PEND_F"
  echo "no change (mode=$have)"
  exit 0
fi

# Debounce: require CONFIRMATIONS consecutive polls agreeing before acting.
prev="$(cat "$PEND_F" 2>/dev/null || echo)"
if [ "$prev" = "$want" ]; then
  n=$(( $(cat "$STATE_DIR/pending_n" 2>/dev/null || echo 1) + 1 ))
else
  n=1
fi
echo "$want" > "$PEND_F"; echo "$n" > "$STATE_DIR/pending_n"

if [ "$n" -ge "$CONFIRMATIONS" ]; then
  echo "sustained change detected ($n polls): $have -> $want"
  switch_to "$want" && rm -f "$PEND_F" "$STATE_DIR/pending_n"
else
  echo "pending switch $have -> $want ($n/$CONFIRMATIONS)"
fi
