#!/bin/bash
# wp-sync-setup.sh — sync wallpapers across machines via syncthing
#
# one script, one curl. works over the internet — no VPN needed.
# syncthing handles discovery, NAT traversal, and encryption.
#
# usage:
#   first machine  — bash wp-sync-setup.sh
#   other machines — bash wp-sync-setup.sh --join DEVICE_ID
#
# env vars:
#   WP_FOLDER_ID — syncthing folder id (default: wallpapers)
#
# what happens:
#   1. installs syncthing + jq via pacman
#   2. starts syncthing, configures shared wallpaper folder
#   3. if --join: adds the introducer device (syncthing connects via global discovery)
#   4. installs wallpaper auto-apply (systemd path unit)
#
# after setup, the introducer needs to accept the new device once in the
# syncthing web UI at http://localhost:8384. after that, syncthing's
# introducer feature propagates all peers automatically.

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
WALLPAPER_DIR="$HOME/Pictures/Wallpapers"
FOLDER_ID="${WP_FOLDER_ID:-wallpapers}"
FOLDER_LABEL="Wallpapers"
ST_PORT=8384
ST_API="http://127.0.0.1:${ST_PORT}"
WP_CONFIG="$HOME/.config/wp-sync"
SYSTEMD_DIR="$HOME/.config/systemd/user"
API_KEY=""  # set after syncthing starts

# ── output ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
else
  R='' G='' Y='' C='' N=''
fi
log()  { printf "${G}::${N} %s\n" "$*"; }
warn() { printf "${Y}::${N} %s\n" "$*"; }
die()  { printf "${R}::${N} %s\n" "$*" >&2; exit 1; }

# ── args ──────────────────────────────────────────────────────────────────────
INTRODUCER_ID=""
MODE="introducer"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --join)
      [[ $# -lt 2 ]] && die "--join requires a device ID"
      INTRODUCER_ID="$2"
      # validate syncthing device ID format: 8 groups of 7 base32 chars
      if ! [[ "$INTRODUCER_ID" =~ ^[A-Z0-9]{7}-[A-Z0-9]{7}-[A-Z0-9]{7}-[A-Z0-9]{7}-[A-Z0-9]{7}-[A-Z0-9]{7}-[A-Z0-9]{7}-[A-Z0-9]{7}$ ]]; then
        die "invalid device ID format: $INTRODUCER_ID"
      fi
      MODE="join"; shift 2 ;;
    -h|--help)
      printf "usage: %s [--join INTRODUCER_DEVICE_ID]\n\n" "$0"
      printf "  first machine:   %s\n" "$0"
      printf "  other machines:  %s --join <DEVICE_ID>\n" "$0"
      printf "\nenv vars:\n"
      printf "  WP_FOLDER_ID  syncthing folder id (default: wallpapers)\n"
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# ── helpers ───────────────────────────────────────────────────────────────────
st() {
  [[ -z "$API_KEY" ]] && die "BUG: st() called before API_KEY is set"
  local method="$1" path="$2" body="${3:-}"
  local args=(-sf -H "X-API-Key: ${API_KEY}" -H "Content-Type: application/json")
  [[ "$method" != "GET" ]] && args+=(-X "$method")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}" "${ST_API}${path}"
}

wait_for_api() {
  local tries=30
  for ((i=1; i<=tries; i++)); do
    # any HTTP response (even 401/403) means syncthing is up
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "$ST_API/rest/system/ping" 2>/dev/null) || true
    [[ "$code" =~ ^[0-9]+$ && "$code" -gt 0 ]] && return 0
    sleep 1
  done
  die "syncthing API not responding after ${tries}s"
}

wait_for_api_down() {
  for ((i=1; i<=20; i++)); do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 1 "$ST_API/rest/system/ping" 2>/dev/null) || true
    [[ -z "$code" || "$code" == "000" ]] && return 0
    sleep 0.5
  done
  warn "syncthing didn't stop within 10s, continuing anyway"
}

# ══════════════════════════════════════════════════════════════════════════════
# step 1: packages
# ══════════════════════════════════════════════════════════════════════════════
log "installing packages..."

for pkg in syncthing jq; do
  if command -v "$pkg" >/dev/null 2>&1; then
    log "  $pkg: already installed"
  else
    sudo pacman -S --needed --noconfirm "$pkg"
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# step 2: syncthing
# ══════════════════════════════════════════════════════════════════════════════
log "starting syncthing..."

# detect config path — v2 uses ~/.local/state, older uses ~/.config
if [[ -f "$HOME/.local/state/syncthing/config.xml" ]]; then
  ST_HOME="$HOME/.local/state/syncthing"
elif [[ -f "$HOME/.config/syncthing/config.xml" ]]; then
  ST_HOME="$HOME/.config/syncthing"
else
  ST_HOME="$HOME/.local/state/syncthing"
  mkdir -p "$ST_HOME"
  if ! syncthing generate --home="$ST_HOME" 2>/dev/null; then
    warn "  'syncthing generate' not available; config will be created on first start"
  else
    log "  generated fresh config at $ST_HOME"
  fi
fi

systemctl --user enable --now syncthing.service
wait_for_api
log "  syncthing api ready"

# ══════════════════════════════════════════════════════════════════════════════
# step 3: read identity
# ══════════════════════════════════════════════════════════════════════════════

# re-detect config path after syncthing starts (it may have created config)
if [[ -f "$HOME/.local/state/syncthing/config.xml" ]]; then
  ST_HOME="$HOME/.local/state/syncthing"
elif [[ -f "$HOME/.config/syncthing/config.xml" ]]; then
  ST_HOME="$HOME/.config/syncthing"
fi

[[ -f "$ST_HOME/config.xml" ]] || die "config.xml not found at $ST_HOME — syncthing may not have started correctly"

API_KEY=$(sed -n 's/.*<apikey>\([^<]*\)<\/apikey>.*/\1/p' "$ST_HOME/config.xml")
[[ -z "$API_KEY" ]] && die "could not read api key from $ST_HOME/config.xml"

MY_ID=$(st GET /rest/system/status | jq -r '.myID')
log "  device id: $MY_ID"

# save identity
mkdir -p "$WP_CONFIG"
chmod 700 "$WP_CONFIG"
printf "DEVICE_ID=%q\nAPI_KEY=%q\n" "$MY_ID" "$API_KEY" > "$WP_CONFIG/identity"
chmod 600 "$WP_CONFIG/identity"

# ══════════════════════════════════════════════════════════════════════════════
# step 4: configure syncthing
# ══════════════════════════════════════════════════════════════════════════════
log "configuring syncthing..."

# auto-accept folders from introducer
st PATCH /rest/config/defaults/device '{"autoAcceptFolders": true}' >/dev/null

# ══════════════════════════════════════════════════════════════════════════════
# step 5: wallpapers folder
# ══════════════════════════════════════════════════════════════════════════════
log "setting up wallpapers folder..."
mkdir -p "$WALLPAPER_DIR"

EXISTING=$(st GET /rest/config/folders | jq -r ".[] | select(.id==\"${FOLDER_ID}\") | .id")
if [[ "$EXISTING" == "$FOLDER_ID" ]]; then
  log "  folder '$FOLDER_ID' already exists"
else
  st POST /rest/config/folders "$(jq -n \
    --arg id "$FOLDER_ID" \
    --arg label "$FOLDER_LABEL" \
    --arg path "$WALLPAPER_DIR" \
    --arg myid "$MY_ID" \
    '{id:$id, label:$label, path:$path, type:"sendreceive",
      rescanIntervalS:60, fsWatcherEnabled:true, fsWatcherDelayS:5,
      devices:[{deviceID:$myid}]}')" >/dev/null
  log "  created folder: $WALLPAPER_DIR"
fi

# ══════════════════════════════════════════════════════════════════════════════
# step 6: device registration
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "introducer" ]]; then
  log "this machine is the introducer"

else
  # ── joining an existing network ──
  log "joining network via introducer..."

  # add introducer device locally
  KNOWN=$(st GET /rest/config/devices | jq -r ".[] | select(.deviceID==\"${INTRODUCER_ID}\") | .deviceID")
  if [[ "$KNOWN" == "$INTRODUCER_ID" ]]; then
    log "  introducer already in local config"
  else
    st POST /rest/config/devices "$(jq -n \
      --arg id "$INTRODUCER_ID" \
      '{deviceID:$id, name:"wp-sync-introducer", addresses:["dynamic"],
        introducer:true, autoAcceptFolders:true}')" >/dev/null
    log "  added introducer to local config"
  fi

  # add introducer to the wallpapers folder
  FOLDER_JSON=$(st GET "/rest/config/folders/${FOLDER_ID}")
  HAS_IT=$(echo "$FOLDER_JSON" | jq -r ".devices[] | select(.deviceID==\"${INTRODUCER_ID}\") | .deviceID")
  if [[ "$HAS_IT" != "$INTRODUCER_ID" ]]; then
    DEVS=$(echo "$FOLDER_JSON" | jq --arg id "$INTRODUCER_ID" '.devices + [{"deviceID":$id}]')
    st PATCH "/rest/config/folders/${FOLDER_ID}" "{\"devices\":${DEVS}}" >/dev/null
    log "  added introducer to wallpapers folder"
  fi

  warn "the introducer needs to accept this device once"
  warn "open http://localhost:8384 on the introducer and click 'Add Device'"
  warn "after that, syncthing handles everything automatically"
fi

# ══════════════════════════════════════════════════════════════════════════════
# step 7: restart syncthing (apply config changes)
# ══════════════════════════════════════════════════════════════════════════════
log "restarting syncthing..."
st POST /rest/system/restart >/dev/null 2>&1 || true
wait_for_api_down
wait_for_api
log "  syncthing restarted"

# ══════════════════════════════════════════════════════════════════════════════
# step 8: wallpaper auto-apply
# ══════════════════════════════════════════════════════════════════════════════
log "installing wallpaper auto-apply..."

mkdir -p "$HOME/.local/bin" "$SYSTEMD_DIR"

# ── apply script ──
cat > "$HOME/.local/bin/wp-sync-apply.sh" <<'SCRIPT'
#!/bin/bash
# apply the newest wallpaper from ~/Pictures/Wallpapers

DIR="$HOME/Pictures/Wallpapers"

# when run from systemd, session env may be missing
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
  while IFS='=' read -r key val; do
    case "$key" in
      DISPLAY|WAYLAND_DISPLAY|XDG_CURRENT_DESKTOP|DESKTOP_SESSION|DBUS_SESSION_BUS_ADDRESS)
        export "$key=$val" ;;
    esac
  done < <(systemctl --user show-environment 2>/dev/null)
fi

sleep 2  # let sync finish writing

IMG=$(find "$DIR" -maxdepth 1 -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
  -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

[[ -z "$IMG" ]] && exit 0

DE=$(echo "${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-}}" | tr '[:upper:]' '[:lower:]')

case "$DE" in
  *gnome*|*unity*|*budgie*|*cinnamon*)
    gsettings set org.gnome.desktop.background picture-uri "file://$IMG"
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$IMG" 2>/dev/null || true ;;
  *kde*|*plasma*)
    plasma-apply-wallpaperimage "$IMG" 2>/dev/null || true ;;
  *sway*)
    swaymsg output '*' bg "$IMG" fill 2>/dev/null || true ;;
  *hyprland*)
    hyprctl hyprpaper unload all 2>/dev/null || true
    hyprctl hyprpaper preload "$IMG" 2>/dev/null || true
    for m in $(hyprctl monitors -j 2>/dev/null | jq -r '.[].name' 2>/dev/null); do
      hyprctl hyprpaper wallpaper "$m,$IMG" 2>/dev/null || true
    done ;;
  *xfce*)
    for p in $(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep last-image); do
      xfconf-query -c xfce4-desktop -p "$p" -s "$IMG" 2>/dev/null || true
    done ;;
  *mate*)
    gsettings set org.mate.background picture-filename "$IMG" 2>/dev/null || true ;;
  *)
    feh --bg-fill "$IMG" 2>/dev/null || nitrogen --set-zoom-fill "$IMG" 2>/dev/null || true ;;
esac
SCRIPT
chmod +x "$HOME/.local/bin/wp-sync-apply.sh"

# ── systemd path unit (triggers on file change) ──
cat > "${SYSTEMD_DIR}/wp-sync-apply.path" <<EOF
[Unit]
Description=Watch wallpapers for changes

[Path]
PathChanged=${WALLPAPER_DIR}

[Install]
WantedBy=default.target
EOF

# ── systemd service (runs the apply script) ──
cat > "${SYSTEMD_DIR}/wp-sync-apply.service" <<EOF
[Unit]
Description=Apply newest wallpaper

[Service]
Type=oneshot
ExecStart=%h/.local/bin/wp-sync-apply.sh
Environment=DISPLAY=${DISPLAY:-:0}
Environment=WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
Environment=DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}
Environment=XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-}
EOF

systemctl --user daemon-reload
systemctl --user enable --now wp-sync-apply.path
log "  wallpaper watcher active"

# ══════════════════════════════════════════════════════════════════════════════
# done
# ══════════════════════════════════════════════════════════════════════════════
printf "\n"
log "setup complete"
printf "\n"
printf "  wallpapers:  %s\n" "$WALLPAPER_DIR"
printf "  folder id:   %s\n" "$FOLDER_ID"
printf "  device id:   %s\n" "$MY_ID"
printf "  syncthing:   http://localhost:%s\n" "$ST_PORT"
printf "\n"

if [[ "$MODE" == "introducer" ]]; then
  printf "  ${C}share this with friends:${N}\n"
  printf "\n"
  printf "    ${C}curl -sL <URL>/wp-sync-setup.sh | bash -s -- --join %s${N}\n" "$MY_ID"
  printf "\n"
  printf "  when they join, accept the device at ${C}http://localhost:%s${N}\n" "$ST_PORT"
  printf "  after that, syncthing syncs everything automatically.\n"
else
  printf "  waiting for introducer to accept this device.\n"
  printf "  once accepted, wallpapers will sync automatically.\n"
fi
printf "\n"
