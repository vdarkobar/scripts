#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
INSTALL_MODE="local"                 # local | cloud

# Local / LXC mode (used only when INSTALL_MODE=local)
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
if [[ -n "$CT_ID" ]]; then
  [[ "$CT_ID" =~ ^[0-9]+$ ]] && (( CT_ID >= 100 && CT_ID <= 999999999 )) \
    || { echo "  ERROR: CT_ID must be an integer >= 100." >&2; exit 1; }
  if pct status "$CT_ID" >/dev/null 2>&1 || qm status "$CT_ID" >/dev/null 2>&1; then
    echo "  ERROR: CT_ID $CT_ID is already in use on this node." >&2
    exit 1
  fi
else
  CT_ID="$(pvesh get /cluster/nextid 2>/dev/null || true)"
fi
HN="pbs"
CPU=2
RAM=2048
DISK=10
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"
TAGS="pbs;backup;lxc"

# Common Debian / PBS settings
DEBIAN_VERSION=13
APP_TZ="Europe/Berlin"
DISABLE_IPV6=0                        # 1 = disable IPv6 inside local CT and via sysctl, 0 = leave enabled
ENABLE_UNATTENDED_UPGRADES=1          # 1 = configure unattended-upgrades, 0 = skip
REBOOT_AFTER_INSTALL=0                # 1 = reboot at end of successful install, 0 = leave running and print reminder

# Cloud / native-on-Debian mode (used only when INSTALL_MODE=cloud)
PBS_UI_ADMIN_USER="admin"
PBS_UI_ADMIN_REALM="pbs"
PBS_UI_ADMIN_AUTHID="${PBS_UI_ADMIN_USER}@${PBS_UI_ADMIN_REALM}"
SSH_PUBKEY=""                        # optional; cloud mode only. if empty, prompt during install

# Extra packages to install (space-separated or array)
EXTRA_PACKAGES=(
  qemu-guest-agent
)

# Behavior
CLEANUP_ON_FAIL=1                     # local mode only: 1 = destroy created CT on error, 0 = keep for debugging

# Derived paths
PROXMOX_SOURCES_FILE="/etc/apt/sources.list.d/proxmox.sources"
PROXMOX_KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"
PROXMOX_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"

# ── Custom configs created by this script ─────────────────────────────────────
# local mode creates/configures inside the PBS CT:
#   /etc/apt/sources.list.d/proxmox.sources
#   /usr/share/keyrings/proxmox-archive-keyring.gpg
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf           (optional)
#   /etc/apt/apt.conf.d/20auto-upgrades                        (optional)
#   /etc/sysctl.d/99-hardening.conf
#   /etc/update-motd.d/00-header                               (local mode only)
#   /etc/update-motd.d/10-sysinfo                              (local mode only)
#   /etc/update-motd.d/30-app                                  (local mode only)
#   /etc/update-motd.d/99-footer                               (local mode only)
# cloud mode creates/configures on the current Debian VM/VPS:
#   /etc/apt/sources.list.d/proxmox.sources
#   /usr/share/keyrings/proxmox-archive-keyring.gpg
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf           (optional)
#   /etc/apt/apt.conf.d/20auto-upgrades                        (optional)
#   /etc/sysctl.d/99-hardening.conf
#   /etc/ssh/sshd_config.d/99-hardening.conf
#   UFW rules for 22/tcp, 80/tcp, 8007/tcp

# ── Trap cleanup ──────────────────────────────────────────────────────────────
trap 'rc=$?;
  trap - ERR
  echo "  ERROR: failed (rc=$rc) near line ${BASH_LINENO[0]:-?}" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${INSTALL_MODE:-}" == "local" && "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' ERR

trap 'rc=$?;
  echo "  Interrupted (rc=$rc)" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${INSTALL_MODE:-}" == "local" && "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' INT TERM

# ── Validate config values ────────────────────────────────────────────────────
[[ "${INSTALL_MODE}" == "local" || "${INSTALL_MODE}" == "cloud" ]] \
  || { echo "  ERROR: INSTALL_MODE must be local or cloud." >&2; exit 1; }

[[ "${DEBIAN_VERSION}" =~ ^[0-9]+$ ]] \
  || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }

[[ "${CPU}" =~ ^[0-9]+$ && "${CPU}" -ge 1 ]] \
  || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }

[[ "${RAM}" =~ ^[0-9]+$ && "${RAM}" -ge 512 ]] \
  || { echo "  ERROR: RAM must be at least 512 MB." >&2; exit 1; }

[[ "${DISK}" =~ ^[0-9]+$ && "${DISK}" -ge 8 ]] \
  || { echo "  ERROR: DISK must be at least 8 GB." >&2; exit 1; }

[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] \
  || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: ${APP_TZ}" >&2; exit 1; }

if [[ "${INSTALL_MODE}" == "local" ]]; then
  [[ -n "${CT_ID}" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
fi

# ── Preflight — root & mode detection ─────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root." >&2; exit 1; }

IS_PVE_HOST=0
if command -v pveversion >/dev/null 2>&1 && [[ -d /etc/pve ]]; then
  IS_PVE_HOST=1
fi

if [[ "${INSTALL_MODE}" == "local" && "${IS_PVE_HOST}" -ne 1 ]]; then
  echo "  ERROR: local mode must be run on the Proxmox VE host." >&2
  exit 1
fi

if [[ "${INSTALL_MODE}" == "cloud" && "${IS_PVE_HOST}" -eq 1 ]]; then
  echo "  ERROR: cloud mode must be run inside a Debian VM/VPS, not on the Proxmox host." >&2
  exit 1
fi

# ── Preflight — commands ──────────────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  for cmd in pvesh pveam pct pvesm python3 ip awk sort paste; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
  done
else
  for cmd in apt-get wget awk ip; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
  done
fi

# ── Discover available resources (local mode only) ───────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
    | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
  AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
    | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
  AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"
fi

# ── Preflight — environment ───────────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
    || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }
  pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
    || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }
  ip link show "$BRIDGE" >/dev/null 2>&1 \
    || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }
else
  [[ -r /etc/os-release ]] || { echo "  ERROR: /etc/os-release not found." >&2; exit 1; }
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || { echo "  ERROR: cloud mode supports Debian only." >&2; exit 1; }
  [[ "${VERSION_CODENAME:-}" == "trixie" ]] || { echo "  ERROR: cloud mode expects Debian 13 (Trixie)." >&2; exit 1; }
  [[ "$(dpkg --print-architecture)" == "amd64" ]] || { echo "  ERROR: cloud mode currently supports amd64 only." >&2; exit 1; }
fi

# ── Show defaults & confirm ───────────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  cat <<EOF2

  PBS LXC Creator — Configuration
  ────────────────────────────────────────
  Install mode:      ${INSTALL_MODE}
  CT ID:             ${CT_ID}
  Hostname:          ${HN}
  CPU cores:         ${CPU}
  RAM (MB):          ${RAM}
  Disk (GB):         ${DISK}
  Bridge:            ${BRIDGE} (${AVAIL_BRIDGES})
  Template storage:  ${TEMPLATE_STORAGE} (${AVAIL_TMPL_STORES})
  Container storage: ${CONTAINER_STORAGE} (${AVAIL_CT_STORES})
  Debian:            ${DEBIAN_VERSION}
  Timezone:          ${APP_TZ}
  Disable IPv6:      ${DISABLE_IPV6}
  Auto-upgrades:     ${ENABLE_UNATTENDED_UPGRADES}
  Reboot at end:     ${REBOOT_AFTER_INSTALL}
  Tags:              ${TAGS}
  Cleanup on fail:   ${CLEANUP_ON_FAIL}
  Login model:       root@pam
  ────────────────────────────────────────

EOF2
else
  cat <<EOF2

  PBS Cloud Installer — Configuration
  ────────────────────────────────────────
  Install mode:      ${INSTALL_MODE}
  Debian:            ${DEBIAN_VERSION}
  Timezone:          ${APP_TZ}
  Disable IPv6:      ${DISABLE_IPV6}
  Auto-upgrades:     ${ENABLE_UNATTENDED_UPGRADES}
  Reboot at end:     ${REBOOT_AFTER_INSTALL}
  Login model:       ${PBS_UI_ADMIN_AUTHID}
  SSH key:           $( [[ -n "${SSH_PUBKEY}" ]] && echo preseeded || echo will prompt )
  Firewall:          UFW enabled (22, 80, 8007)
  ────────────────────────────────────────

EOF2
fi

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *) exit 0 ;;
esac
echo ""

# ── Prompt for local root password ────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
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
fi

# ── Cloud mode note ───────────────────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  echo "  cloud mode leaves existing SSH configuration untouched"
  echo ""
fi

# ── Cloud mode — SSH key prompt and validation ──────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  if [[ -z "${SSH_PUBKEY}" ]]; then
    while true; do
      read -r -p "  Enter SSH public key for root access (leave empty to cancel): " SSH_PUBKEY
      [[ -n "${SSH_PUBKEY}" ]] || { echo "  ERROR: SSH public key is required in cloud mode." >&2; exit 1; }

      if [[ "${SSH_PUBKEY}" == *$'\n'* ]]; then
        echo "  SSH public key must be a single line."
        continue
      fi

      case "${SSH_PUBKEY}" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *)
          ;;
        *)
          echo "  Unsupported SSH public key type."
          continue
          ;;
      esac

      SSH_KEY_B64="$(printf '%s' "${SSH_PUBKEY}" | awk '{print $2}')"
      [[ -n "${SSH_KEY_B64}" ]] || { echo "  SSH public key is missing the base64 payload."; continue; }
      printf '%s' "${SSH_KEY_B64}" | grep -Eq '^[A-Za-z0-9+/=]+$' || { echo "  SSH public key payload is not valid base64 text."; continue; }
      [[ ${#SSH_KEY_B64} -ge 32 ]] || { echo "  SSH public key payload looks too short."; continue; }
      unset SSH_KEY_B64
      break
    done
    echo ""
  else
    if [[ "${SSH_PUBKEY}" == *$'\n'* ]]; then
      echo "  ERROR: SSH_PUBKEY must be a single line." >&2
      exit 1
    fi
    case "${SSH_PUBKEY}" in
      ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *)
        ;;
      *)
        echo "  ERROR: SSH_PUBKEY has an unsupported key type." >&2
        exit 1
        ;;
    esac
    SSH_KEY_B64="$(printf '%s' "${SSH_PUBKEY}" | awk '{print $2}')"
    [[ -n "${SSH_KEY_B64}" ]] || { echo "  ERROR: SSH_PUBKEY is missing the base64 payload." >&2; exit 1; }
    printf '%s' "${SSH_KEY_B64}" | grep -Eq '^[A-Za-z0-9+/=]+$' || { echo "  ERROR: SSH_PUBKEY payload is not valid base64 text." >&2; exit 1; }
    [[ ${#SSH_KEY_B64} -ge 32 ]] || { echo "  ERROR: SSH_PUBKEY payload looks too short." >&2; exit 1; }
    unset SSH_KEY_B64
  fi
fi

# ── Cloud mode — PBS admin password prompt ───────────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  while true; do
    read -r -s -p "  Set password for ${PBS_UI_ADMIN_AUTHID}: " PBS_UI_ADMIN_PASSWORD; echo
    if [[ -z "$PBS_UI_ADMIN_PASSWORD" ]]; then echo "  Password cannot be blank."; continue; fi
    if [[ "$PBS_UI_ADMIN_PASSWORD" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
    if [[ ${#PBS_UI_ADMIN_PASSWORD} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
    read -r -s -p "  Verify password for ${PBS_UI_ADMIN_AUTHID}: " PBS_UI_ADMIN_PASSWORD_CONFIRM; echo
    if [[ "$PBS_UI_ADMIN_PASSWORD" == "$PBS_UI_ADMIN_PASSWORD_CONFIRM" ]]; then break; fi
    echo "  Passwords do not match. Try again."
  done
  unset PBS_UI_ADMIN_PASSWORD_CONFIRM
  echo ""
fi

# ── Local mode — template discovery & download ───────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
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
fi

# ── Local mode — create LXC ───────────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  if [[ "${DISABLE_IPV6}" -eq 1 ]]; then
    LXC_IP6_MODE="manual"
  else
    LXC_IP6_MODE="auto"
  fi

  PCT_OPTIONS=(
    -hostname "$HN"
    -cores "$CPU"
    -memory "$RAM"
    -rootfs "${CONTAINER_STORAGE}:${DISK}"
    -onboot 1
    -ostype debian
    -unprivileged 1
    -features "nesting=1"
    -tags "$TAGS"
    -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=${LXC_IP6_MODE}"
    -password "$PASSWORD"
  )

  pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
  CREATED=1
fi

# ── Local mode — start and wait for IPv4 ─────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
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
fi

# ── Local mode — OS bootstrap in CT ──────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
    systemctl disable -q --now systemd-networkd-wait-online.service 2>/dev/null || true
    apt-get update -qq
    apt-get -o Dpkg::Options::="--force-confold" -y dist-upgrade
    apt-get -y autoremove
    apt-get -y clean
  '

  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y locales ca-certificates curl wget
    sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8
  '

  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
    echo '${APP_TZ}' > /etc/timezone
  "
fi

# ── Local mode — add PBS repo and install full package set ───────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    mkdir -p /etc/apt/sources.list.d /usr/share/keyrings
    cat > /etc/apt/sources.list.d/proxmox.sources <<EOF2
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF2
    wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -O /usr/share/keyrings/proxmox-archive-keyring.gpg
    chmod 0644 /usr/share/keyrings/proxmox-archive-keyring.gpg

    echo "postfix postfix/mailname string $(hostname -f 2>/dev/null || hostname)" | debconf-set-selections
    echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y proxmox-backup
    systemctl restart proxmox-backup-proxy 2>/dev/null || true
  '
fi

# ── Local mode — wait for PBS web UI ─────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  PBS_READY=0
  for i in $(seq 1 30); do
    if pct exec "$CT_ID" -- bash -lc 'curl -kfsS https://127.0.0.1:8007/ >/dev/null 2>&1'; then
      PBS_READY=1
      break
    fi
    sleep 2
  done

  if [[ "$PBS_READY" -ne 1 ]]; then
    echo "  WARNING: PBS web UI on port 8007 did not answer yet — check inside the CT." >&2
    pct exec "$CT_ID" -- systemctl --no-pager --full status proxmox-backup-proxy >&2 || true
  fi
fi

# ── Local mode — unattended upgrades ──────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" && "${ENABLE_UNATTENDED_UPGRADES}" -eq 1 ]]; then
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
Unattended-Upgrade::Package-Blacklist {
};
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
fi

# ── Local mode — extra packages ──────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" && "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

# ── Local mode — sysctl hardening ────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
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
  '

  if [[ "${DISABLE_IPV6}" -eq 1 ]]; then
    pct exec "$CT_ID" -- bash -lc '
      set -euo pipefail
      cat >> /etc/sysctl.d/99-hardening.conf <<EOF2
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF2
    '
  fi

  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    sysctl --system >/dev/null 2>&1 || true
  '
fi

# ── Local mode — cleanup packages ────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y man-db manpages 2>/dev/null || true
    apt-get -y autoremove
    apt-get -y clean
  '
fi

# ── Local mode — MOTD and terminal quality-of-life ───────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    > /etc/motd
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
    rm -f /etc/update-motd.d/*

    cat > /etc/update-motd.d/00-header <<"MOTD"
#!/bin/sh
printf "\n  Proxmox Backup Server\n"
printf "  ────────────────────────────────────\n"
MOTD

    cat > /etc/update-motd.d/10-sysinfo <<"MOTD"
#!/bin/sh
ip=$(ip -4 -o addr show scope global 2>/dev/null | awk "{print $4}" | cut -d/ -f1 | head -n1)
printf "  Hostname:  %s\n" "$(hostname)"
printf "  IP:        %s\n" "${ip:-n/a}"
printf "  Uptime:    %s\n" "$(uptime -p 2>/dev/null || uptime)"
printf "  Disk:      %s\n" "$(df -h / | awk "NR==2{printf \"%s/%s (%s used)\", $3, $2, $5}")"
MOTD

    cat > /etc/update-motd.d/30-app <<"MOTD"
#!/bin/sh
proxy_state=$(systemctl is-active proxmox-backup-proxy 2>/dev/null || echo unknown)
printf "  Proxy:     %s\n" "$proxy_state"
printf "  Web UI:    https://%s:8007/\n" "$(ip -4 -o addr show scope global 2>/dev/null | awk "{print $4}" | cut -d/ -f1 | head -n1)"
printf "  Login:     root@pam\n"
printf "  Repo:      pbs-no-subscription\n"
printf "  Notes:     configure datastore after first login\n"
printf "  Reboot:    recommended once after install\n"
MOTD

    cat > /etc/update-motd.d/99-footer <<"MOTD"
#!/bin/sh
printf "  ────────────────────────────────────\n\n"
MOTD

    chmod +x /etc/update-motd.d/*
  '

  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    touch /root/.bashrc
    grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
  '
fi

# ── Local mode — Proxmox UI description and protection ───────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  DESC="<a href='https://${CT_IP}:8007/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>PBS Web UI</a>
<details><summary>Details</summary>Proxmox Backup Server on Debian ${DEBIAN_VERSION} LXC
Install mode: local
Login: root@pam
Created by pbs-integrated.sh</details>"
  pct set "$CT_ID" --description "$DESC"
  pct set "$CT_ID" --protection 1
fi

# ── Cloud mode — baseline OS update and timezone ─────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8

  # Disable any pre-existing PBS enterprise repo on reused cloud images.
  # The cloud path is meant to use pbs-no-subscription only.
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -e "$f" ]] || continue
    if grep -qsE 'enterprise\.proxmox\.com/debian/pbs' "$f"; then
      mv -f "$f" "$f.disabled"
    fi
  done

  apt-get update -qq
  apt-get -o Dpkg::Options::="--force-confold" -y dist-upgrade
  apt-get -y autoremove
  apt-get -y clean

  apt-get update -qq
  apt-get install -y locales ca-certificates curl wget
  sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8

  ln -sf "/usr/share/zoneinfo/${APP_TZ}" /etc/localtime
  echo "${APP_TZ}" > /etc/timezone
fi

# ── Cloud mode — add PBS repo and install minimal package set ────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  mkdir -p /etc/apt/sources.list.d /usr/share/keyrings
  cat > "${PROXMOX_SOURCES_FILE}" <<EOF2
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF2
  wget -q "${PROXMOX_KEY_URL}" -O "${PROXMOX_KEYRING}"
  chmod 0644 "${PROXMOX_KEYRING}"

  echo "postfix postfix/mailname string $(hostname -f 2>/dev/null || hostname)" | debconf-set-selections
  echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y ca-certificates curl proxmox-backup-server ufw

  # Disable any PBS enterprise source the package may have dropped.
  # Match by content rather than filename because source filenames can vary.
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -e "$f" ]] || continue
    if grep -qsE 'enterprise\.proxmox\.com/debian/pbs' "$f"; then
      mv -f "$f" "$f.disabled"
    fi
  done

  apt-get update -qq
  systemctl restart proxmox-backup-proxy 2>/dev/null || true
fi

# ── Cloud mode — install root SSH authorized key ─────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  install -d -m 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  grep -Fxq "${SSH_PUBKEY}" /root/.ssh/authorized_keys || printf '%s\n' "${SSH_PUBKEY}" >> /root/.ssh/authorized_keys
fi

# ── Cloud mode — SSH hardening drop-in ───────────────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF2
PermitRootLogin prohibit-password
PasswordAuthentication no
AuthenticationMethods publickey
EOF2
  if sshd -t; then
    systemctl restart ssh
  else
    echo "  WARNING: sshd config validation failed — SSH hardening not applied." >&2
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
  fi
fi

# ── Cloud mode — configure firewall without changing SSH policy ──────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  # Reset is intentional here so reused VPS images start from a known UFW state.
  # SSH on 22/tcp is re-allowed immediately below.
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 8007/tcp
  ufw --force enable
fi

# ── Cloud mode — create dedicated PBS UI admin if missing ────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  PBS_USER_EXISTS=0
  if proxmox-backup-manager user list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "${PBS_UI_ADMIN_AUTHID}"; then
    PBS_USER_EXISTS=1
  fi

  if [[ "${PBS_USER_EXISTS}" -eq 0 ]]; then
    proxmox-backup-manager user create "${PBS_UI_ADMIN_AUTHID}" \
      --password "${PBS_UI_ADMIN_PASSWORD}" \
      --comment "Dedicated PBS web UI administrator"

    unset PBS_UI_ADMIN_PASSWORD
  else
    echo "  PBS user already exists: ${PBS_UI_ADMIN_AUTHID}"
  fi

  proxmox-backup-manager acl update / Admin --auth-id "${PBS_UI_ADMIN_AUTHID}"
  proxmox-backup-manager user permissions "${PBS_UI_ADMIN_AUTHID}" --path /
fi

# ── Cloud mode — wait for PBS web UI ─────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  PBS_READY=0
  for i in $(seq 1 30); do
    if curl -kfsS https://127.0.0.1:8007/ >/dev/null 2>&1; then
      PBS_READY=1
      break
    fi
    sleep 2
  done

  if [[ "$PBS_READY" -ne 1 ]]; then
    echo "  WARNING: PBS web UI on port 8007 did not answer yet — check this VM/VPS manually." >&2
    systemctl --no-pager --full status proxmox-backup-proxy >&2 || true
  fi
fi

# ── Cloud mode — unattended upgrades ──────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" && "${ENABLE_UNATTENDED_UPGRADES}" -eq 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive

  # Re-disable any PBS enterprise repo before later APT operations.
  # This keeps the cloud path resilient if an enterprise source reappears.
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -e "$f" ]] || continue
    if grep -qsE 'enterprise\.proxmox\.com/debian/pbs' "$f"; then
      mv -f "$f" "$f.disabled"
    fi
  done

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
Unattended-Upgrade::Package-Blacklist {
};
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
fi

# ── Cloud mode — sysctl hardening ────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
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

  if [[ "${DISABLE_IPV6}" -eq 1 ]]; then
    cat >> /etc/sysctl.d/99-hardening.conf <<EOF2
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF2
  fi

  sysctl --system >/dev/null 2>&1 || true
fi

# ── Cloud mode — final package cleanup ────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
fi

# ── Local mode — summary ──────────────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "local" ]]; then
  echo ""
  echo "  CT:        ${CT_ID}"
  echo "  IP:        ${CT_IP}"
  echo "  Web UI:    https://${CT_IP}:8007/"
  echo "  Login:     root@pam"
  echo "  Notes:     configure datastore after first login"
  echo "  SSH:       not required for local mode; manage with pct exec / pct enter"
  if [[ "${REBOOT_AFTER_INSTALL}" -eq 0 ]]; then
    echo "  Reboot:    recommended once after install"
  fi
  echo ""
fi

# ── Cloud mode — summary ──────────────────────────────────────────────────────
if [[ "${INSTALL_MODE}" == "cloud" ]]; then
  CLOUD_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  echo ""
  echo "  Host:      $(hostname)"
  echo "  IP:        ${CLOUD_IP:-n/a}"
  echo "  Web UI:    https://${CLOUD_IP:-<this-host>}:8007/"
  echo "  Login:     ${PBS_UI_ADMIN_USER} / realm: Proxmox Backup authentication server"
  echo "  Notes:     configure datastore after first login"
  echo "  SSH:       root key only; password auth disabled"
  if [[ "${REBOOT_AFTER_INSTALL}" -eq 0 ]]; then
    echo "  Reboot:    recommended once after install"
  fi
  echo ""
fi

# ── Optional reboot after successful install ──────────────────────────────────
if [[ "${REBOOT_AFTER_INSTALL}" -eq 1 ]]; then
  if [[ "${INSTALL_MODE}" == "local" ]]; then
    echo "  Rebooting CT ${CT_ID} ..."
    pct reboot "$CT_ID"
  else
    echo "  Rebooting this VM/VPS ..."
    systemctl reboot
  fi
else
  echo "  Done."
fi
