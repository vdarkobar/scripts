#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="stirling-pdf"
CPU=2
RAM=4096
DISK=10
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Stirling-PDF / Podman
APP_PORT=8080
APP_TZ="Europe/Berlin"
PUBLIC_FQDN=""                       # e.g. stirling.example.com ; blank = local IP mode
TAGS="stirling-pdf;podman;lxc"

# Images / versions
APP_IMAGE_REPO="docker.io/stirlingtools/stirling-pdf"
APP_TAG="latest-fat"                 # floating tag — user-requested; no concrete pin available
DEBIAN_VERSION=13

# Optional features
AUTO_UPDATE=0                        # 1 = enable timer-driven maintenance/update runs
TRACK_LATEST=0                       # 1 = auto-update overrides APP_TAG with latest-fat
                                     # only meaningful when APP_TAG is pinned to a concrete
                                     # version (e.g. 0.46.2-fat); when APP_TAG is already a
                                     # floating tag like latest-fat, both modes re-pull the
                                     # same image

# Behavior
CLEANUP_ON_FAIL=1

# Derived
APP_DIR="/opt/stirling-pdf"
APP_IMAGE="${APP_IMAGE_REPO}:${APP_TAG}"

# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/stirling-pdf/docker-compose.yml      (Podman compose stack)
#   /opt/stirling-pdf/.env                    (runtime configuration)
#   /opt/stirling-pdf/configs/                (app settings + database)
#   /opt/stirling-pdf/tessdata/               (OCR language packs — eng, deu)
#   /opt/stirling-pdf/logs/                   (application logs)
#   /opt/stirling-pdf/pipeline/               (automation configurations)
#   /usr/local/bin/stirling-maint.sh          (maintenance helper)
#   /etc/systemd/system/stirling-stack.service
#   /etc/systemd/system/stirling-update.service
#   /etc/systemd/system/stirling-update.timer
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

# ── Config validation ─────────────────────────────────────────────────────────
[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
[[ "$CPU" =~ ^[0-9]+$ ]] && (( CPU >= 1 && CPU <= 128 )) || { echo "  ERROR: CPU must be between 1 and 128." >&2; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] && (( RAM >= 512 )) || { echo "  ERROR: RAM must be at least 512 MB." >&2; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] && (( DISK >= 2 )) || { echo "  ERROR: DISK must be at least 2 GB." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { echo "  ERROR: APP_PORT must be numeric." >&2; exit 1; }
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || { echo "  ERROR: APP_PORT must be between 1 and 65535." >&2; exit 1; }
[[ "$AUTO_UPDATE" =~ ^[01]$ ]] || { echo "  ERROR: AUTO_UPDATE must be 0 or 1." >&2; exit 1; }
[[ "$TRACK_LATEST" =~ ^[01]$ ]] || { echo "  ERROR: TRACK_LATEST must be 0 or 1." >&2; exit 1; }
[[ "$APP_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "  ERROR: APP_TAG contains invalid characters: $APP_TAG" >&2; exit 1; }
if [[ -n "$PUBLIC_FQDN" && ! "$PUBLIC_FQDN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "  ERROR: PUBLIC_FQDN contains invalid characters: $PUBLIC_FQDN" >&2
  exit 1
fi

# ── Trap cleanup ──────────────────────────────────────────────────────────────
trap 'rc=$?;
  trap - ERR
  echo "  ERROR: failed (rc=$rc) near line ${BASH_LINENO[0]:-?}" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' ERR

trap 'rc=$?;
  echo "  Interrupted (rc=$rc)" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' INT TERM

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm curl python3 ip awk sort paste; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  Stirling-PDF (Podman) LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU cores:         $CPU
  RAM (MB):          $RAM
  Disk (GB):         $DISK
  Bridge:            $BRIDGE ($AVAIL_BRIDGES)
  Template storage:  $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container storage: $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  Debian:            $DEBIAN_VERSION
  App image:         $APP_IMAGE
  App port:          $APP_PORT
  OCR packs:         eng, deu
  Public FQDN:       ${PUBLIC_FQDN:-"(not set — local IP mode)"}
  Timezone:          $APP_TZ
  Tags:              $TAGS
  Auto-update:       $([ "$AUTO_UPDATE" -eq 1 ] && echo "enabled" || echo "disabled")
  Track latest:      $([ "$TRACK_LATEST" -eq 1 ] && echo "enabled" || echo "disabled")
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/stirling-pdf-podman.sh"
SCRIPT_LOCAL="/root/stirling-pdf-podman.sh"
SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Saving current script to ${SCRIPT_LOCAL} for editing..."
    if [[ -f "$SCRIPT_SELF" ]] && cp -f -- "$SCRIPT_SELF" "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
      echo "  Edit:  nano ${SCRIPT_LOCAL}"
      echo "  Run:   bash ${SCRIPT_LOCAL}"
      echo ""
    elif curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
      echo "  WARNING: Could not copy the running script; downloaded fallback from GitHub instead."
      echo "  Edit:  nano ${SCRIPT_LOCAL}"
      echo "  Run:   bash ${SCRIPT_LOCAL}"
      echo ""
    else
      echo "  ERROR: Failed to save a local editable copy of the script." >&2
    fi
    exit 0
    ;;
esac

echo ""

# ── Preflight — environment ───────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }
pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }
ip link show "$BRIDGE" >/dev/null 2>&1 \
  || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password ─────────────────────────────────────────────────────────────
PASSWORD=""
while true; do
  read -r -s -p "  Set root password: " PW1; echo
  if [[ -z "$PW1" ]]; then echo "  Password cannot be blank."; continue; fi
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done

echo ""

# ── Template discovery & download ─────────────────────────────────────────────
pveam update

echo ""
TEMPLATE="$(pveam available -section system | awk -v p="debian-${DEBIAN_VERSION}" '$2 ~ ("^" p) {print $2}' | sort -V | tail -n1)"
if [[ -z "$TEMPLATE" ]]; then
  echo "  WARNING: No Debian ${DEBIAN_VERSION} template found, trying any Debian..." >&2
  TEMPLATE="$(pveam available -section system | awk '$2 ~ /^debian-/ {print $2}' | sort -V | tail -n1)"
fi
[[ -n "$TEMPLATE" ]] || { echo "  ERROR: No Debian template found via pveam." >&2; exit 1; }
echo "  Template: $TEMPLATE"

if [[ "$TEMPLATE_STORAGE" == "local" && -f "/var/lib/vz/template/cache/$TEMPLATE" ]]; then
  echo "  Template already present: $TEMPLATE"
else
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ── Create LXC ────────────────────────────────────────────────────────────────
PCT_OPTIONS=(
  -hostname "$HN"
  -cores "$CPU"
  -memory "$RAM"
  -rootfs "${CONTAINER_STORAGE}:${DISK}"
  -onboot 1
  -ostype debian
  -unprivileged 1
  -features "nesting=1,keyctl=1,fuse=1"
  -tags "$TAGS"
  -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=manual"
  -password "$PASSWORD"
)

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

# ── Start & wait for IPv4 ─────────────────────────────────────────────────────
pct start "$CT_ID"
CT_IP=""
for i in $(seq 1 30); do
  CT_IP="$(pct exec "$CT_ID" -- sh -lc '
    ip -4 -o addr show scope global 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -n1
  ' 2>/dev/null || true)"
  [[ -n "$CT_IP" ]] && break
  sleep 1
done
[[ -n "$CT_IP" ]] || { echo "  ERROR: No IPv4 address acquired via DHCP within timeout." >&2; exit 1; }
echo "  CT $CT_ID is up — IP: $CT_IP"

# ── OS update ─────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  systemctl disable -q --now systemd-networkd-wait-online.service 2>/dev/null || true
  apt-get update -qq
  apt-get -o Dpkg::Options::="--force-confold" -y dist-upgrade
  apt-get -y autoremove
  apt-get clean
'

# ── Base packages, locale, timezone ───────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y locales curl ca-certificates iproute2 jq podman podman-compose fuse-overlayfs
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

# ── Remove unnecessary services ───────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now ssh 2>/dev/null || true
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y openssh-server postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Podman configuration ──────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/containers

  cat > /etc/containers/storage.conf <<EOF2
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF2

  cat > /etc/containers/containers.conf <<EOF2
[containers]
log_size_max = 10485760
EOF2
'

pct exec "$CT_ID" -- podman info >/dev/null 2>&1
pct exec "$CT_ID" -- podman --version
pct exec "$CT_ID" -- podman-compose --version

# ── Pull images ───────────────────────────────────────────────────────────────
echo "  Pulling Stirling-PDF image ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  podman pull '${APP_IMAGE}'
"

# ── Prepare persistent paths ──────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  install -d -m 0755 '${APP_DIR}'
  install -d -m 0755 '${APP_DIR}/configs'
  install -d -m 0755 '${APP_DIR}/tessdata'
  install -d -m 0755 '${APP_DIR}/logs'
  install -d -m 0755 '${APP_DIR}/pipeline'
"

# ── Download OCR language packs (eng + deu) ───────────────────────────────────
echo "  Downloading Tesseract OCR language packs (eng, deu) ..."
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  TESS_URL='https://github.com/tesseract-ocr/tessdata_fast/raw/main'
  curl -fsSL \"\${TESS_URL}/eng.traineddata\" -o '${APP_DIR}/tessdata/eng.traineddata'
  curl -fsSL \"\${TESS_URL}/deu.traineddata\" -o '${APP_DIR}/tessdata/deu.traineddata'
  echo '  eng.traineddata and deu.traineddata downloaded'
  ls -lh '${APP_DIR}/tessdata/'
"

# ── Compose file ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "cat > '${APP_DIR}/docker-compose.yml' <<'EOF2'
services:
  stirling-pdf:
    image: \${APP_IMAGE}
    container_name: stirling-pdf
    ports:
      - \"\${APP_PORT}:8080\"
    volumes:
      - /opt/stirling-pdf/tessdata:/usr/share/tessdata:Z
      - /opt/stirling-pdf/configs:/configs:Z
      - /opt/stirling-pdf/logs:/logs:Z
      - /opt/stirling-pdf/pipeline:/pipeline:Z
    environment:
      SECURITY_ENABLELOGIN: \"false\"
      DISABLE_ADDITIONAL_FEATURES: \"false\"
      SYSTEM_ENABLEANALYTICS: \"false\"
      SYSTEM_ENABLESCARF: \"false\"
      LANGS: en_GB
      TZ: \${APP_TZ}
    restart: unless-stopped
EOF2"

# ── Runtime .env ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${APP_DIR}/.env' <<EOF2
COMPOSE_PROJECT_NAME=stirling-pdf
APP_IMAGE_REPO=${APP_IMAGE_REPO}
APP_TAG=${APP_TAG}
APP_IMAGE=${APP_IMAGE}
APP_PORT=${APP_PORT}
APP_TZ=${APP_TZ}
PUBLIC_FQDN=${PUBLIC_FQDN}
AUTO_UPDATE=${AUTO_UPDATE}
TRACK_LATEST=${TRACK_LATEST}
EOF2
  chmod 0600 '${APP_DIR}/.env' '${APP_DIR}/docker-compose.yml'
"

# ── Maintenance script ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/stirling-maint.sh && chmod 0755 /usr/local/bin/stirling-maint.sh' <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

APP_DIR="${APP_DIR:-/opt/stirling-pdf}"
SERVICE="stirling-stack.service"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

need_root() { [[ $EUID -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }; }
die() { echo "  ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF2
  Stirling-PDF Maintenance
  ────────────────────────
  Usage:
    $0 update [image-tag]
    $0 auto-update
    $0 version

  Notes:
    - update re-pulls the image and recreates the container
    - auto-update obeys AUTO_UPDATE and TRACK_LATEST from ${ENV_FILE}
    - take a PVE snapshot before running a manual update
    - backup and restore are handled by PBS / PVE snapshots
EOF2
}

[[ -d "$APP_DIR" ]] || die "APP_DIR not found: $APP_DIR"
[[ -f "$ENV_FILE" ]] || die "Missing env file: $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]] || die "Missing compose file: $COMPOSE_FILE"

current_image() {
  awk -F= '/^APP_IMAGE=/{print $2}' "$ENV_FILE" | tail -n1
}

current_tag() {
  local img
  img="$(current_image)"
  echo "${img##*:}"
}

current_repo() {
  awk -F= '/^APP_IMAGE_REPO=/{print $2}' "$ENV_FILE" | tail -n1
}

env_flag() {
  local key="$1" raw
  raw="$(awk -F= -v key="$key" '$1==key{print $2}' "$ENV_FILE" | tail -n1 | tr -d '[:space:]')"
  [[ "$raw" =~ ^[01]$ ]] && printf '%s' "$raw" || printf '0'
}

auto_update_enabled() {
  [[ "$(env_flag AUTO_UPDATE)" == "1" ]]
}

track_latest_enabled() {
  [[ "$(env_flag TRACK_LATEST)" == "1" ]]
}

resolve_auto_tag() {
  if track_latest_enabled; then
    printf '%s\n' latest-fat
  else
    current_tag
  fi
}

update_stirling() {
  local new_tag="${1:-}"
  local interactive="${2:-1}"
  local repo old_tag new_image tmp_env

  repo="$(current_repo)"
  old_tag="$(current_tag)"
  [[ -n "$repo" ]] || die "Could not read APP_IMAGE_REPO from .env"

  if [[ -z "$new_tag" ]]; then
    new_tag="$old_tag"
    echo "  No tag specified — re-pulling current tag: $old_tag"
  fi

  [[ "$new_tag" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid image tag: $new_tag"
  new_image="${repo}:${new_tag}"

  echo "  Current tag: $old_tag"
  echo "  Target  tag: $new_tag"

  if [[ "$interactive" -eq 1 ]]; then
    echo ""
    echo "  IMPORTANT: Take a PVE snapshot before proceeding."
    read -r -p "  Continue? [y/N]: " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY]) ;;
      *) echo "  Aborted."; exit 0 ;;
    esac
  fi

  echo "  Pulling target image ..."
  podman pull "$new_image"

  tmp_env="$(mktemp)"
  cp -a "$ENV_FILE" "$tmp_env"

  cleanup() { rm -f "$tmp_env"; }
  rollback() {
    trap - ERR
    echo "  !! Update failed — rolling back .env and restarting old container ..." >&2
    cp -a "$tmp_env" "$ENV_FILE"
    cd "$APP_DIR"
    /usr/bin/podman-compose up -d || true
  }

  # Arm rollback only after pull succeeds — .env is about to be mutated
  trap rollback ERR

  sed -i \
    -e "s|^APP_TAG=.*|APP_TAG=$new_tag|" \
    -e "s|^APP_IMAGE=.*|APP_IMAGE=$new_image|" \
    "$ENV_FILE"

  echo "  Recreating Stirling-PDF container ..."
  cd "$APP_DIR"
  /usr/bin/podman-compose down
  /usr/bin/podman-compose up -d

  echo "  Waiting for Stirling-PDF ..."
  local healthy=0
  for i in $(seq 1 45); do
    if curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:"$(awk -F= '/^APP_PORT=/{print $2}' "$ENV_FILE" | tail -n1)"/; then
      healthy=1
      break
    fi
    sleep 2
  done
  if [[ "$healthy" -eq 1 ]]; then
    echo "  Health check passed"
  else
    echo "  NOTE: Not responding yet — fat image may take 2-4 minutes on first start." >&2
  fi

  trap - ERR
  cleanup
  echo "  OK: Stirling-PDF updated to $new_tag"
}

auto_update_stirling() {
  local target_tag cur_tag

  if ! auto_update_enabled; then
    echo "  Auto-update disabled in ${ENV_FILE}; nothing to do."
    return 0
  fi

  cur_tag="$(current_tag)"
  target_tag="$(resolve_auto_tag)"

  if track_latest_enabled; then
    if [[ "$cur_tag" == "latest-fat" || "$cur_tag" == "latest" ]]; then
      echo "  Auto-update policy: TRACK_LATEST=1, but APP_TAG is already floating ($cur_tag)"
      echo "  Note: TRACK_LATEST only changes behavior when APP_TAG is pinned to a concrete version."
    else
      echo "  Auto-update policy: TRACK_LATEST=1 -> overriding pinned tag $cur_tag with latest-fat"
    fi
  else
    echo "  Auto-update policy: TRACK_LATEST=0 -> re-pulling configured tag $cur_tag"
  fi

  update_stirling "$target_tag" 0
}

need_root
cmd="${1:-}"
case "$cmd" in
  update) shift; update_stirling "${1:-}" ;;
  auto-update) auto_update_stirling ;;
  version)
    echo "Configured image: $(current_image)"
    echo "AUTO_UPDATE=$(env_flag AUTO_UPDATE)"
    echo "TRACK_LATEST=$(env_flag TRACK_LATEST)"
    ;;
  ""|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
MAINT
echo "  Maintenance script deployed: /usr/local/bin/stirling-maint.sh"

# ── Systemd stack unit ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/stirling-stack.service <<EOF2
[Unit]
Description=Stirling-PDF (Podman) stack
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/stirling-pdf
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose stop
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable --now stirling-stack.service
'

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3
if pct exec "$CT_ID" -- systemctl is-active --quiet stirling-stack.service 2>/dev/null; then
  echo "  Stirling-PDF stack service is active"
else
  echo "  WARNING: stirling-stack.service may not be active — check: pct exec $CT_ID -- journalctl -u stirling-stack --no-pager -n 50" >&2
fi

RUNNING=0
for i in $(seq 1 60); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge 1 ]] && break
  sleep 2
done
pct exec "$CT_ID" -- bash -lc 'cd /opt/stirling-pdf && podman-compose ps' || true

STIRLING_HEALTHY=0
for i in $(seq 1 45); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${APP_PORT}/ 2>/dev/null" 2>/dev/null || echo 000)"
  if [[ "$HTTP_CODE" =~ ^(200|302)$ ]]; then
    STIRLING_HEALTHY=1
    break
  fi
  sleep 2
done

if [[ "$STIRLING_HEALTHY" -eq 1 ]]; then
  echo "  Health check passed (HTTP $HTTP_CODE on port ${APP_PORT})"
else
  echo "  NOTE: Not responding on port ${APP_PORT} yet — this is normal with the fat image." >&2
  echo "  The fat image bundles LibreOffice + OCR tools and may take 2-4 minutes on first start." >&2
  echo "  Container is running; the web UI will become available shortly." >&2
fi

# ── Auto-update timer (policy-driven) ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/systemd/system/stirling-update.service <<EOF2
[Unit]
Description=Stirling-PDF auto-update maintenance run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/stirling-maint.sh auto-update
EOF2

  cat > /etc/systemd/system/stirling-update.timer <<EOF2
[Unit]
Description=Stirling-PDF auto-update timer

[Timer]
OnCalendar=*-*-01 05:30:00
OnCalendar=*-*-15 05:30:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF2

  systemctl daemon-reload
'
if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc 'systemctl enable --now stirling-update.timer'
  echo "  Auto-update timer enabled"
else
  pct exec "$CT_ID" -- bash -lc 'systemctl disable --now stirling-update.timer >/dev/null 2>&1 || true'
  echo "  Auto-update timer installed but disabled"
fi

# ── Unattended upgrades ───────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades
  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/apt.conf.d/52unattended-$(hostname).conf <<EOF2
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security";
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-updates,label=Debian";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF2
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF2
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF2
  systemctl enable --now unattended-upgrades
'

# ── Sysctl hardening ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/sysctl.d/99-hardening.conf <<EOF2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF2
  sysctl --system >/dev/null 2>&1 || true
'

# ── Cleanup packages ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get clean
'

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'EOF2'
#!/bin/sh
printf '\n  Stirling-PDF (Podman)\n'
printf '  ────────────────────────────────────\n'
EOF2

  cat > /etc/update-motd.d/10-sysinfo <<'EOF2'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' \"\$(hostname)\"
printf '  IP:        %s\n' \"\${ip:-n/a}\"
printf '  Uptime:    %s\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
EOF2

  cat > /etc/update-motd.d/30-app <<'EOF2'
#!/bin/sh
running=\$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
service_active=\$(systemctl is-active stirling-stack.service 2>/dev/null || echo 'unknown')
configured_image=\$(awk -F= '/^APP_IMAGE=/{print \$2}' /opt/stirling-pdf/.env 2>/dev/null | tail -n1)
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '\n  App:\n'
printf '    Stack:     /opt/stirling-pdf (%s containers running)\n' \"\$running\"
printf '    Service:   %s\n' \"\$service_active\"
printf '    Image:     %s\n' \"\${configured_image:-n/a}\"
printf '    OCR:       eng, deu\n'
printf '    Compose:   cd /opt/stirling-pdf && podman-compose [up -d|down|logs|ps]\n'
printf '    Maintain:  stirling-maint.sh [update|auto-update|version]\n'
printf '    Web UI:    http://%s:${APP_PORT}\n' \"\${ip:-n/a}\"
[ -n '${PUBLIC_FQDN}' ] && printf '    Public:    https://${PUBLIC_FQDN}\n' || true
printf '\n'
EOF2

  cat > /etc/update-motd.d/99-footer <<'EOF2'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
EOF2

  chmod +x /etc/update-motd.d/*
"

# Set TERM for console
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
STIRLING_LOCAL="<a href='http://${CT_IP}:${APP_PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Stirling-PDF (local)</a>"
STIRLING_PUBLIC=""
if [[ -n "$PUBLIC_FQDN" ]]; then
  STIRLING_PUBLIC="
<a href='https://${PUBLIC_FQDN}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Stirling-PDF (public)</a>"
fi
STIRLING_DESC="${STIRLING_LOCAL}${STIRLING_PUBLIC}
<details><summary>Details</summary>Stirling-PDF ${APP_TAG} on Debian ${DEBIAN_VERSION} LXC
Podman single-container deployment
OCR: eng, deu
Created by stirling-pdf-podman.sh</details>"
pct set "$CT_ID" --description "$STIRLING_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Login: password set"
echo ""
echo "  Access (local):"
echo "    Web UI: http://${CT_IP}:${APP_PORT}/"
if [[ -n "$PUBLIC_FQDN" ]]; then
  echo ""
  echo "  Access (public):"
  echo "    Web UI: https://${PUBLIC_FQDN}/"
fi
echo ""
echo "  Deployment:"
echo "    Image:  $APP_IMAGE"
echo "    OCR:    eng, deu (tessdata_fast)"
echo ""
echo "  Config files:"
echo "    ${APP_DIR}/docker-compose.yml"
echo "    ${APP_DIR}/.env"
echo ""
echo "  Persistent paths:"
echo "    ${APP_DIR}/configs"
echo "    ${APP_DIR}/tessdata"
echo "    ${APP_DIR}/logs"
echo "    ${APP_DIR}/pipeline"
echo ""
echo "  Maintenance:"
echo "    Policy: AUTO_UPDATE=${AUTO_UPDATE} TRACK_LATEST=${TRACK_LATEST}"
echo "    pct exec $CT_ID -- stirling-maint.sh update [tag]"
echo "    pct exec $CT_ID -- stirling-maint.sh auto-update"
echo "    pct exec $CT_ID -- stirling-maint.sh version"
echo ""
if [[ -n "$PUBLIC_FQDN" ]]; then
  echo "  Reverse proxy (NPM):"
  echo "    ${PUBLIC_FQDN} -> http://${CT_IP}:${APP_PORT}"
  echo "    Enable SSL in NPM."
  echo ""
fi
echo "  Done."
