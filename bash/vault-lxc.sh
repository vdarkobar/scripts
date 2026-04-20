#!/usr/bin/env bash
set -Eeuo pipefail

# vault-lxc.sh — Proxmox VE creator for a hardened SSH vault LXC.
# Creates a fresh Debian LXC, installs + hardens sshd for a single admin
# user, and drops in the vault-key helper. This is a CREATOR, not an
# idempotent reconciler: running it against a host where the chosen CT_ID
# already exists is rejected in preflight, not patched in place. Re-running
# against an existing vault CT is not supported — tear down and re-create.

# ── Config ────────────────────────────────────────────────────────────────────
# LXC sizing & placement
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="vault"
CPU=1
RAM=1024
DISK=4
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Debian / tagging
APP_TZ="Europe/Berlin"
TAGS="debian;lxc;vault"
DEBIAN_VERSION=13

# Extra packages (on top of the base + vault packages added below)
# Note: qemu-guest-agent is a QEMU/KVM package and has no effect in an LXC.
EXTRA_PACKAGES=(
  curl
)

# Vault admin user
ADMIN_USER="admin"
ADMIN_COMMENT="Vault User"
ADMIN_SHELL="/bin/bash"
ADMIN_GROUPS=(sudo)

# SSH service on the vault CT itself
SSH_PORT=22
SSH_LISTEN_ADDRESS=""                # blank = all addresses
ALLOW_TCP_FORWARDING=0
ALLOW_AGENT_FORWARDING=0
ALLOW_X11_FORWARDING=0

# Helper paths (inside the CT)
VAULT_HELPER_PATH="/usr/local/bin/vault-key"
SSHD_DROPIN_PATH="/etc/ssh/sshd_config.d/10-vault-hardening.conf"

# Behavior flags
DISABLE_IPV6=0                       # 1 = also disable IPv6 via sysctl hardening
LOCK_ROOT_PASSWORD=1                 # 1 = lock local root password after setup; pct enter still works
CLEANUP_ON_FAIL=1                    # 1 = destroy CT on error, 0 = keep for debugging

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-vault
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf
#   /etc/ssh/sshd_config.d/10-vault-hardening.conf
#   /usr/local/bin/vault-key

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
  [[ -n "${HOST_TMPDIR:-}" && -d "${HOST_TMPDIR}" ]] && rm -rf "${HOST_TMPDIR}" || true
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
  [[ -n "${HOST_TMPDIR:-}" && -d "${HOST_TMPDIR}" ]] && rm -rf "${HOST_TMPDIR}" || true
  exit "$rc"
' INT TERM

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct qm pvesm curl python3 ip awk grep sed sort paste seq mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# ── Config validation ─────────────────────────────────────────────────────────
if [[ -n "$CT_ID" ]]; then
  [[ "$CT_ID" =~ ^[0-9]+$ ]] && (( CT_ID >= 100 && CT_ID <= 999999999 )) \
    || { echo "  ERROR: CT_ID must be an integer >= 100." >&2; exit 1; }
  if pct status "$CT_ID" >/dev/null 2>&1 || qm status "$CT_ID" >/dev/null 2>&1; then
    echo "  ERROR: CT_ID $CT_ID is already in use on this node." >&2
    exit 1
  fi
  # Also check the rest of the cluster: VMIDs are cluster-wide.
  CT_ID_CLUSTER_HIT="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | TARGET="$CT_ID" python3 -c "
import sys, json, os
vmid = int(os.environ['TARGET'])
data = json.load(sys.stdin)
print('yes' if any(r.get('vmid') == vmid for r in data) else 'no')
" 2>/dev/null || echo "unknown")"
  case "$CT_ID_CLUSTER_HIT" in
    yes)     echo "  ERROR: CT_ID $CT_ID is already in use elsewhere on the cluster." >&2; exit 1 ;;
    no)      : ;;
    *)       echo "  WARNING: Could not verify CT_ID $CT_ID against cluster resources; proceeding." >&2 ;;
  esac
else
  CT_ID="$(pvesh get /cluster/nextid)"
  [[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
fi

[[ "$CPU" =~ ^[0-9]+$ ]] || { echo "  ERROR: CPU must be numeric." >&2; exit 1; }
[[ "$RAM" =~ ^[0-9]+$ ]] || { echo "  ERROR: RAM must be numeric." >&2; exit 1; }
[[ "$DISK" =~ ^[0-9]+$ ]] || { echo "  ERROR: DISK must be numeric." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$DISABLE_IPV6" =~ ^[01]$ ]] || { echo "  ERROR: DISABLE_IPV6 must be 0 or 1." >&2; exit 1; }
[[ "$LOCK_ROOT_PASSWORD" =~ ^[01]$ ]] || { echo "  ERROR: LOCK_ROOT_PASSWORD must be 0 or 1." >&2; exit 1; }
[[ "$CLEANUP_ON_FAIL" =~ ^[01]$ ]] || { echo "  ERROR: CLEANUP_ON_FAIL must be 0 or 1." >&2; exit 1; }

if [[ ! "$APP_TZ" =~ ^[A-Za-z0-9._/+:-]+$ ]]; then
  echo "  ERROR: APP_TZ contains invalid characters: $APP_TZ" >&2
  exit 1
fi
[[ -f "/usr/share/zoneinfo/$APP_TZ" ]] \
  || { echo "  ERROR: Timezone does not exist in zoneinfo: $APP_TZ" >&2; exit 1; }

# RFC 1123-style hostname validation:
#   - each label: 1-63 chars, starts + ends with alphanumeric, hyphens only in the middle
#   - labels separated by single dots, no trailing dot, no empty labels
#   - total length <= 253 chars (FQDN bound)
if (( ${#HN} > 253 )) \
   || ! [[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
  echo "  ERROR: Invalid hostname: $HN" >&2
  echo "         Each label must be 1-63 chars, start and end with alphanumeric," >&2
  echo "         hyphens allowed in middle, single dots between labels, no trailing dot." >&2
  exit 1
fi

[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
  || { echo "  ERROR: ADMIN_USER must match ^[a-z_][a-z0-9_-]{0,31}$" >&2; exit 1; }
[[ "$ADMIN_USER" != "root" ]] || { echo "  ERROR: ADMIN_USER must not be root." >&2; exit 1; }

[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) \
  || { echo "  ERROR: SSH_PORT must be between 1 and 65535." >&2; exit 1; }

[[ "$ALLOW_TCP_FORWARDING" =~ ^[01]$ ]]   || { echo "  ERROR: ALLOW_TCP_FORWARDING must be 0 or 1." >&2; exit 1; }
[[ "$ALLOW_AGENT_FORWARDING" =~ ^[01]$ ]] || { echo "  ERROR: ALLOW_AGENT_FORWARDING must be 0 or 1." >&2; exit 1; }
[[ "$ALLOW_X11_FORWARDING" =~ ^[01]$ ]]   || { echo "  ERROR: ALLOW_X11_FORWARDING must be 0 or 1." >&2; exit 1; }

if [[ -n "$SSH_LISTEN_ADDRESS" ]] && ! [[ "$SSH_LISTEN_ADDRESS" =~ ^[A-Za-z0-9:._-]+$ ]]; then
  echo "  ERROR: SSH_LISTEN_ADDRESS contains invalid characters." >&2
  exit 1
fi

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF2

  Vault LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:               $CT_ID
  Hostname:            $HN
  CPU:                 $CPU core(s)
  RAM:                 $RAM MiB
  Disk:                $DISK GB
  Bridge:              $BRIDGE ($AVAIL_BRIDGES)
  Template Storage:    $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container Storage:   $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  Debian Version:      $DEBIAN_VERSION
  Timezone:            $APP_TZ
  Tags:                $TAGS
  ────────────────────────────────────────
  Admin user:          $ADMIN_USER
  Admin shell:         $ADMIN_SHELL
  SSH port:            $SSH_PORT
  SSH listen address:  ${SSH_LISTEN_ADDRESS:-<all>}
  TCP forwarding:      $([ "$ALLOW_TCP_FORWARDING" -eq 1 ] && echo 'yes' || echo 'no')
  Agent forwarding:    $([ "$ALLOW_AGENT_FORWARDING" -eq 1 ] && echo 'yes' || echo 'no')
  X11 forwarding:      $([ "$ALLOW_X11_FORWARDING" -eq 1 ] && echo 'yes' || echo 'no')
  Lock root password:  $([ "$LOCK_ROOT_PASSWORD" -eq 1 ] && echo 'yes (no prompt; root left locked)' || echo 'no (will prompt)')
  IPv6:                $([ "$DISABLE_IPV6" -eq 1 ] && echo 'disabled (net + sysctl)' || echo 'auto (SLAAC)')
  Cleanup on fail:     $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  After this script runs, inbound SSH to the vault CT stays
  locked until you add a public key to:
    /home/$ADMIN_USER/.ssh/authorized_keys
  pct enter remains available as a fallback.

  To change defaults, press Enter and edit the Config section
  at the top of this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/vault-lxc.sh"
SCRIPT_LOCAL="/root/vault-lxc.sh"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Saving script to ${SCRIPT_LOCAL} for editing..."
    if [[ -f "$SCRIPT_SOURCE" && -r "$SCRIPT_SOURCE" ]] && cat "$SCRIPT_SOURCE" > "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
      echo "  Edit:  nano ${SCRIPT_LOCAL}"
      echo "  Run:   bash ${SCRIPT_LOCAL}"
      echo ""
    elif curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
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
# Validate both existence AND content capability. Plain existence is not
# enough: a storage that exists but doesn't advertise the content type will
# fail later at pct create / pveam download time with a cryptic error.
STORAGE_INFO="$(pvesh get /storage --output-format json 2>/dev/null || true)"
[[ -n "$STORAGE_INFO" ]] \
  || { echo "  ERROR: Could not query storage configuration via pvesh." >&2; exit 1; }

TMPL_CHECK="$(printf '%s' "$STORAGE_INFO" | TARGET="$TEMPLATE_STORAGE" python3 -c "
import sys, json, os
target = os.environ['TARGET']
for s in json.load(sys.stdin):
    if s.get('storage') == target:
        print('ok' if 'vztmpl' in s.get('content', '') else 'no-content')
        sys.exit(0)
print('missing')
" 2>/dev/null || echo "missing")"
case "$TMPL_CHECK" in
  ok)         : ;;
  no-content) echo "  ERROR: Template storage '$TEMPLATE_STORAGE' does not support 'vztmpl' content." >&2; exit 1 ;;
  *)          echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1 ;;
esac

CT_CHECK="$(printf '%s' "$STORAGE_INFO" | TARGET="$CONTAINER_STORAGE" python3 -c "
import sys, json, os
target = os.environ['TARGET']
for s in json.load(sys.stdin):
    if s.get('storage') == target:
        print('ok' if 'rootdir' in s.get('content', '') else 'no-content')
        sys.exit(0)
print('missing')
" 2>/dev/null || echo "missing")"
case "$CT_CHECK" in
  ok)         : ;;
  no-content) echo "  ERROR: Container storage '$CONTAINER_STORAGE' does not support 'rootdir' content." >&2; exit 1 ;;
  *)          echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1 ;;
esac

ip link show "$BRIDGE" >/dev/null 2>&1 || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Credentials prompts ───────────────────────────────────────────────────────
# Root password is prompted ONLY when LOCK_ROOT_PASSWORD=0. In the default
# (locked) case no root password exists anywhere — avoids exposing a secret
# we're going to discard seconds later, and avoids passing it as pct create
# argv. pct enter from the PVE host still works either way.
#
# Admin password is always prompted: it's for local sudo / su / console,
# not for inbound SSH (which is pubkey-only).

ROOT_PASSWORD=""
if [[ "$LOCK_ROOT_PASSWORD" -eq 0 ]]; then
  while true; do
    read -r -s -p "  Set root password: " PW1; echo
    if [[ -z "$PW1" ]]; then echo "  Password cannot be blank."; continue; fi
    if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
    if [[ "$PW1" == *:* ]]; then echo "  Password cannot contain a colon (chpasswd uses user:password)."; continue; fi
    if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
    read -r -s -p "  Verify root password: " PW2; echo
    if [[ "$PW1" == "$PW2" ]]; then ROOT_PASSWORD="$PW1"; break; fi
    echo "  Passwords do not match. Try again."
  done
  unset PW1 PW2
fi

ADMIN_PASSWORD=""
while true; do
  read -r -s -p "  Set local login/sudo password for ${ADMIN_USER}: " PW1; echo
  [[ -n "$PW1" ]] || { echo "  Password cannot be blank."; continue; }
  [[ "$PW1" != *" "* ]] || { echo "  Password cannot contain spaces."; continue; }
  [[ "$PW1" != *:* ]] || { echo "  Password cannot contain a colon (chpasswd uses user:password)."; continue; }
  (( ${#PW1} >= 8 )) || { echo "  Password must be at least 8 characters."; continue; }
  read -r -s -p "  Verify password for ${ADMIN_USER}: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then ADMIN_PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done
unset PW1 PW2

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
# Build the net0 option so DISABLE_IPV6 actually governs IPv6 behavior at
# the LXC interface level (not just sysctl inside the guest).
NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
if [[ "$DISABLE_IPV6" -eq 1 ]]; then
  NET0+=",ip6=manual"
else
  NET0+=",ip6=auto"
fi

# Pre-quote array contents once, here. Piping %q-quoted tokens through the
# double-quoted `bash -lc "..."` boundary is safer than unquoted array[*]
# splicing and robust against unusual package / group names.
EXTRA_PACKAGES_Q="$(printf ' %q' "${EXTRA_PACKAGES[@]}")"
ADMIN_GROUPS_Q="$(printf ' %q' "${ADMIN_GROUPS[@]}")"

# No -features nesting=1: a vault has no use for nested containers.
# No -password: root stays locked by default (LOCK_ROOT_PASSWORD=1), or is
# set post-start via `chpasswd` stdin (LOCK_ROOT_PASSWORD=0). Either way
# the root password never appears as pct create argv.
PCT_OPTIONS=(
  -hostname "$HN"
  -cores "$CPU"
  -memory "$RAM"
  -rootfs "${CONTAINER_STORAGE}:${DISK}"
  -onboot 1
  -ostype debian
  -unprivileged 1
  -tags "$TAGS"
  -net0 "$NET0"
)

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

# ── Start & wait for IPv4 ─────────────────────────────────────────────────────
pct start "$CT_ID"

CT_IP=""
for i in $(seq 1 30); do
  CT_IP="$({
    pct exec "$CT_ID" -- sh -lc '
      ip -4 -o addr show scope global 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -n1
    ' 2>/dev/null || true
  })"
  [[ -n "$CT_IP" ]] && break
  sleep 1
done
[[ -n "$CT_IP" ]] || { echo "  ERROR: No IPv4 address acquired via DHCP within timeout." >&2; exit 1; }

# ── Root password (only when LOCK_ROOT_PASSWORD=0) ────────────────────────────
# Transported via stdin, never as pct exec argv.
if [[ "$LOCK_ROOT_PASSWORD" -eq 0 && -n "$ROOT_PASSWORD" ]]; then
  printf 'root:%s\n' "$ROOT_PASSWORD" | pct exec "$CT_ID" -- chpasswd
  echo "  Root password set"
fi
unset ROOT_PASSWORD

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
  apt-get -y clean
'

# ── Configure locale ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y locales
  sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
'

# ── Base + vault packages ─────────────────────────────────────────────────────
# NOTE: openssh-server is deliberately INSTALLED and KEPT here — this CT's
# purpose is to be an SSH vault. deblxc.sh purges it; this creator does not.
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends \
    openssh-server openssh-client sudo ca-certificates
'

# ── Remove unnecessary services (postfix only; keep SSH) ──────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Set timezone ──────────────────────────────────────────────────────────────
# Host-side validation already confirmed APP_TZ exists in the PVE host's
# zoneinfo. Belt-and-suspenders: ensure tzdata is present in the CT (should
# already be there in a standard Debian template) and re-verify the zoneinfo
# entry inside the CT before linking. Guards against stale or stripped
# templates where the exact entry happens to be missing.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  dpkg -s tzdata >/dev/null 2>&1 || apt-get install -y tzdata
  [[ -f '/usr/share/zoneinfo/${APP_TZ}' ]] \
    || { echo '  ERROR: Timezone ${APP_TZ} not available in CT tzdata.' >&2; exit 1; }
  ln -sf '/usr/share/zoneinfo/${APP_TZ}' /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

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

  # Note: the apt-daily.timer and apt-daily-upgrade.timer units are enabled
  # by default on Debian and drive unattended-upgrades via the APT periodic
  # config above. No explicit `systemctl enable --now unattended-upgrades`
  # is needed (and it would be a noop-or-worse depending on unit semantics).
'

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y${EXTRA_PACKAGES_Q}
  "
fi

# ── Sysctl hardening ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /etc/sysctl.d/99-hardening.conf <<'EOF2'
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
  if [[ \"${DISABLE_IPV6}\" -eq 1 ]]; then
    cat >> /etc/sysctl.d/99-hardening.conf <<'EOF2'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF2
  fi
  sysctl --system >/dev/null 2>&1 || true
"

# ── Vault: admin user creation ────────────────────────────────────────────────
# Create/adjust admin user, add to sudo group, scaffold ~/.ssh structure.
# ADMIN_GROUP is resolved inside the CT because user-private-group policy
# may differ across Debian variants.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  if ! getent passwd '${ADMIN_USER}' >/dev/null 2>&1; then
    useradd -m -s '${ADMIN_SHELL}' -c '${ADMIN_COMMENT}' '${ADMIN_USER}'
    echo '  Created user: ${ADMIN_USER}'
  else
    usermod -s '${ADMIN_SHELL}' '${ADMIN_USER}'
    echo '  User already exists: ${ADMIN_USER}'
  fi

  for grp in${ADMIN_GROUPS_Q}; do
    getent group \"\$grp\" >/dev/null 2>&1 || groupadd \"\$grp\"
    usermod -aG \"\$grp\" '${ADMIN_USER}'
  done

  # Ensure standard Debian sudo behavior: user password required
  rm -f \"/etc/sudoers.d/90-${ADMIN_USER}-nopasswd\"
"

# Set admin password via stdin (never on the command line)
printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | pct exec "$CT_ID" -- chpasswd
unset ADMIN_PASSWORD

# Scaffold ~/.ssh/{,keys} + ~/.ssh/config
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  ADMIN_GROUP=\"\$(id -gn '${ADMIN_USER}')\"
  [[ -n \"\$ADMIN_GROUP\" ]] || { echo '  ERROR: Could not resolve primary group for ${ADMIN_USER}' >&2; exit 1; }

  ADMIN_HOME=\"\$(getent passwd '${ADMIN_USER}' | awk -F: '{print \$6}')\"
  [[ -n \"\$ADMIN_HOME\" && -d \"\$ADMIN_HOME\" ]] || { echo '  ERROR: Could not resolve home for ${ADMIN_USER}' >&2; exit 1; }

  install -d -m 0700 -o '${ADMIN_USER}' -g \"\$ADMIN_GROUP\" \"\$ADMIN_HOME/.ssh\"
  install -d -m 0700 -o '${ADMIN_USER}' -g \"\$ADMIN_GROUP\" \"\$ADMIN_HOME/.ssh/keys\"
  [[ -e \"\$ADMIN_HOME/.ssh/authorized_keys\" ]] || touch \"\$ADMIN_HOME/.ssh/authorized_keys\"
  [[ -e \"\$ADMIN_HOME/.ssh/known_hosts\"     ]] || touch \"\$ADMIN_HOME/.ssh/known_hosts\"
  chown '${ADMIN_USER}':\"\$ADMIN_GROUP\" \"\$ADMIN_HOME/.ssh/authorized_keys\" \"\$ADMIN_HOME/.ssh/known_hosts\"
  chmod 0600 \"\$ADMIN_HOME/.ssh/authorized_keys\" \"\$ADMIN_HOME/.ssh/known_hosts\"

  if [[ ! -f \"\$ADMIN_HOME/.ssh/config\" ]]; then
    cat > \"\$ADMIN_HOME/.ssh/config\" <<'CFG'
Host *
    HashKnownHosts yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 3
    IdentitiesOnly yes
    ForwardAgent no

# Host cloud-example
#     HostName 203.0.113.10
#     User debian
#     IdentityFile ~/.ssh/keys/cloud-example/id_ed25519
CFG
    chown '${ADMIN_USER}':\"\$ADMIN_GROUP\" \"\$ADMIN_HOME/.ssh/config\"
    chmod 0600 \"\$ADMIN_HOME/.ssh/config\"
  fi

  chown -R '${ADMIN_USER}':\"\$ADMIN_GROUP\" \"\$ADMIN_HOME/.ssh\"
  chmod 0700 \"\$ADMIN_HOME/.ssh\" \"\$ADMIN_HOME/.ssh/keys\"
  chmod 0600 \"\$ADMIN_HOME/.ssh/authorized_keys\" \"\$ADMIN_HOME/.ssh/config\" \"\$ADMIN_HOME/.ssh/known_hosts\"
"

# ── Vault: build vault-key helper on host, push into CT ───────────────────────
HOST_TMPDIR="$(mktemp -d)"
VAULTKEY_SRC="${HOST_TMPDIR}/vault-key"

cat > "$VAULTKEY_SRC" <<'VAULTKEY_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  exec sudo -H -u "$SUDO_USER" -- "$0" "$@"
fi
if [[ $EUID -eq 0 ]]; then
  echo "  ERROR: Run vault-key as your unprivileged user, not as root." >&2
  exit 1
fi

HOME_DIR="$HOME"
SSH_DIR="${HOME_DIR}/.ssh"
KEYS_DIR="${SSH_DIR}/keys"
CONFIG_FILE="${SSH_DIR}/config"

die() {
  echo "  ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  vault-key help
  vault-key list
  vault-key add <alias> [host] [remote_user] [port]
  vault-key show-pub <alias>
  vault-key show-path <alias>
  vault-key export <alias>
  vault-key remove [-y|--yes] <alias>

Notes:
  • vault-key manages outbound SSH keys for cloud targets.
  • It does not add inbound login keys to ~/.ssh/authorized_keys on this vault host.

Examples:
  vault-key add web1
  vault-key add web1 203.0.113.10 debian
  vault-key add aws-bastion-eu bastion.example.com admin 22
  vault-key export web1
  vault-key list
USAGE
}

validate_alias() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "Alias may contain only letters, numbers, dot, underscore, and dash."
}

validate_host() {
  local host="$1"
  [[ -z "$host" || "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || die "Invalid host."
}

validate_remote_user() {
  local remote_user="$1"
  [[ -z "$remote_user" || "$remote_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid remote_user."
}

validate_port() {
  local port="$1"
  [[ -z "$port" ]] && return 0
  [[ "$port" =~ ^[0-9]+$ ]] || die "Port must be numeric."
  (( port >= 1 && port <= 65535 )) || die "Port must be between 1 and 65535."
}

host_alias_exists() {
  local key_alias="$1"
  # Goal: prevent silently duplicating a user's hand-written 'Host <alias>'
  # block. We only flag literal matches. Wildcards (Host *, Host prod-*) are
  # deliberately ignored — they are scaffold / intentional overlays, not
  # collisions, and blocking on them would reject the very scaffold this
  # script installs.
  awk -v key_alias="$key_alias" '
    tolower($1)=="host" {
      for (i = 2; i <= NF; i++) {
        pat = $i
        if (pat ~ /^!/) continue
        if (pat ~ /[*?]/) continue
        if (pat == key_alias) found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$CONFIG_FILE"
}

ensure_scaffold() {
  [[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || die "Could not determine target home directory."

  install -d -m 0700 "$SSH_DIR" "$KEYS_DIR"
  touch "${SSH_DIR}/authorized_keys" "${SSH_DIR}/known_hosts"
  chmod 0600 "${SSH_DIR}/authorized_keys" "${SSH_DIR}/known_hosts"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" <<'CFG'
Host *
    HashKnownHosts yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 3
    IdentitiesOnly yes
    ForwardAgent no

# Host cloud-example
#     HostName 203.0.113.10
#     User debian
#     IdentityFile ~/.ssh/keys/cloud-example/id_ed25519
CFG
    chmod 0600 "$CONFIG_FILE"
  fi
}

add_config_block() {
  local key_alias="$1" host="${2:-}" remote_user="${3:-}" port="${4:-}"
  [[ -n "$host" ]] || return 0

  if grep -Fqx "# BEGIN vault-key ${key_alias}" "$CONFIG_FILE" 2>/dev/null; then
    echo "  SSH config entry already exists for ${key_alias}"
    return 0
  fi

  if host_alias_exists "$key_alias"; then
    die "SSH config already contains Host ${key_alias}; resolve that entry manually first."
  fi

  {
    echo
    echo "# BEGIN vault-key ${key_alias}"
    echo "Host ${key_alias}"
    echo "    HostName ${host}"
    [[ -n "$remote_user" ]] && echo "    User ${remote_user}"
    [[ -n "$port" ]] && echo "    Port ${port}"
    echo "    IdentityFile ~/.ssh/keys/${key_alias}/id_ed25519"
    echo "# END vault-key ${key_alias}"
  } >> "$CONFIG_FILE"

  chmod 0600 "$CONFIG_FILE"
  echo "  Added SSH config entry for ${key_alias}"
}

remove_config_block() {
  local key_alias="$1" tmp
  [[ -f "$CONFIG_FILE" ]] || return 0
  tmp="$(mktemp)"
  awk -v begin="# BEGIN vault-key ${key_alias}" -v end="# END vault-key ${key_alias}" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip { print }
  ' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  chmod 0600 "$CONFIG_FILE"
}

ensure_scaffold

cmd="${1:-help}"

case "$cmd" in
  help|-h|--help)
    usage
    ;;
  list)
    shopt -s nullglob
    entries=("$KEYS_DIR"/*/)
    shopt -u nullglob
    if (( ${#entries[@]} == 0 )); then
      echo "  No keys found under ${KEYS_DIR}"
      exit 0
    fi
    for d in "${entries[@]}"; do
      key_alias="$(basename "$d")"
      printf '  %-24s %s\n' "$key_alias" "${d%/}/id_ed25519.pub"
    done
    ;;
  add)
    key_alias="${2:-}"
    host="${3:-}"
    remote_user="${4:-}"
    port="${5:-}"

    [[ -n "$key_alias" ]] || die "Usage: vault-key add <alias> [host] [remote_user] [port]"
    validate_alias "$key_alias"
    validate_host "$host"
    validate_remote_user "$remote_user"
    validate_port "$port"

    if [[ -n "$host" ]] && ! grep -Fqx "# BEGIN vault-key ${key_alias}" "$CONFIG_FILE" 2>/dev/null; then
      if host_alias_exists "$key_alias"; then
        die "SSH config already contains Host ${key_alias}; resolve that entry manually first."
      fi
    fi

    key_dir="${KEYS_DIR}/${key_alias}"
    priv="${key_dir}/id_ed25519"
    pub="${priv}.pub"

    [[ ! -e "$priv" && ! -e "$pub" ]] || die "Key already exists for alias: ${key_alias}"

    install -d -m 0700 "$key_dir"
    ssh-keygen -q -a 64 -t ed25519 -f "$priv" -N "" -C "${key_alias}"
    chmod 0600 "$priv"
    chmod 0644 "$pub"

    add_config_block "$key_alias" "$host" "$remote_user" "$port"

    echo "  Created key: ${priv}"
    echo "  Public key:"
    cat "$pub"
    ;;
  show-pub)
    key_alias="${2:-}"
    [[ -n "$key_alias" ]] || die "Usage: vault-key show-pub <alias>"
    validate_alias "$key_alias"
    pub="${KEYS_DIR}/${key_alias}/id_ed25519.pub"
    [[ -f "$pub" ]] || die "No such key: ${key_alias}"
    cat "$pub"
    ;;
  show-path)
    key_alias="${2:-}"
    [[ -n "$key_alias" ]] || die "Usage: vault-key show-path <alias>"
    validate_alias "$key_alias"
    priv="${KEYS_DIR}/${key_alias}/id_ed25519"
    pub="${priv}.pub"
    [[ -f "$priv" && -f "$pub" ]] || die "No such key: ${key_alias}"
    printf 'Private: %s\nPublic:  %s\n' "$priv" "$pub"
    ;;
  export)
    key_alias="${2:-}"
    [[ -n "$key_alias" ]] || die "Usage: vault-key export <alias>"
    validate_alias "$key_alias"
    pub="${KEYS_DIR}/${key_alias}/id_ed25519.pub"
    [[ -f "$pub" ]] || die "No such key: ${key_alias}"
    printf 'Name: %s\n' "$key_alias"
    printf 'Type: %s\n' "$(awk '{print $1}' "$pub")"
    printf 'Suggested cloud label: %s-%s\n' "$(hostname -s 2>/dev/null || echo vault)" "$key_alias"
    printf 'Public key:\n'
    cat "$pub"
    ;;
  remove)
    force=0
    case "${2:-}" in
      -y|--yes)
        force=1
        key_alias="${3:-}"
        ;;
      *)
        key_alias="${2:-}"
        ;;
    esac
    [[ -n "$key_alias" ]] || die "Usage: vault-key remove [-y|--yes] <alias>"
    validate_alias "$key_alias"
    key_dir="${KEYS_DIR}/${key_alias}"
    [[ -d "$key_dir" ]] || die "No such key: ${key_alias}"

    if (( force == 0 )); then
      read -r -p "  Really delete key '${key_alias}'? [y/N]: " reply
      case "$reply" in
        [yY][eE][sS]|[yY]) ;;
        *)
          echo "  Aborted."
          exit 0
          ;;
      esac
    fi

    rm -rf "$key_dir"
    remove_config_block "$key_alias"
    echo "  Removed key and SSH config block for ${key_alias}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
VAULTKEY_EOF

pct push "$CT_ID" "$VAULTKEY_SRC" "$VAULT_HELPER_PATH" --perms 0755

# ── Vault: build sshd hardening drop-in on host, push into CT ─────────────────
SSHD_SRC="${HOST_TMPDIR}/10-vault-hardening.conf"
{
  echo "Port $SSH_PORT"
  echo "PermitRootLogin no"
  echo "PubkeyAuthentication yes"
  echo "PasswordAuthentication no"
  echo "KbdInteractiveAuthentication no"
  echo "ChallengeResponseAuthentication no"
  echo "AuthenticationMethods publickey"
  echo "UsePAM yes"
  echo "PermitEmptyPasswords no"
  echo "PermitUserEnvironment no"
  echo "AuthorizedKeysFile .ssh/authorized_keys"
  echo "MaxAuthTries 3"
  echo "LoginGraceTime 30"
  echo "AllowUsers $ADMIN_USER"
  echo "AllowTcpForwarding $([ "$ALLOW_TCP_FORWARDING" -eq 1 ] && echo yes || echo no)"
  echo "AllowAgentForwarding $([ "$ALLOW_AGENT_FORWARDING" -eq 1 ] && echo yes || echo no)"
  echo "X11Forwarding $([ "$ALLOW_X11_FORWARDING" -eq 1 ] && echo yes || echo no)"
  echo "PermitTunnel no"
  echo "ClientAliveInterval 300"
  echo "ClientAliveCountMax 2"
  [[ -n "$SSH_LISTEN_ADDRESS" ]] && echo "ListenAddress $SSH_LISTEN_ADDRESS"
} > "$SSHD_SRC"

# Ensure /etc/ssh/sshd_config.d/*.conf is actually included, then push the
# drop-in, test, and restart. On sshd -t failure we remove the drop-in and
# let the trap handle CT cleanup.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/ssh/sshd_config.d
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/[^[:space:]]+\.conf([[:space:]]|\$)' /etc/ssh/sshd_config; then
    printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
  fi
"

pct push "$CT_ID" "$SSHD_SRC" "$SSHD_DROPIN_PATH" --perms 0644

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  if ! sshd -t; then
    echo '  ERROR: sshd configuration test failed. Removing vault drop-in.' >&2
    rm -f '${SSHD_DROPIN_PATH}'
    exit 1
  fi
  systemctl enable ssh >/dev/null
  systemctl restart ssh
  echo '  SSH hardened for user: ${ADMIN_USER}'
"

# ── Vault: lock root password (optional) ──────────────────────────────────────
# pct enter on the PVE host still works regardless of this lock.
if [[ "$LOCK_ROOT_PASSWORD" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    passwd -l root >/dev/null
    echo "  Root password locked"
  '
fi

# ── Vault: verification ───────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  systemctl is-active --quiet ssh || { echo '  ERROR: ssh service is not active.' >&2; exit 1; }
  if command -v ss >/dev/null 2>&1; then
    ss -H -tln \"sport = :${SSH_PORT}\" | grep -q . \
      || { echo '  ERROR: nothing listening on port ${SSH_PORT}.' >&2; exit 1; }
  fi
  echo '  Verification: sshd active and listening on ${SSH_PORT}'
"

# ── Cleanup packages ──────────────────────────────────────────────────────────
# Keep man-db + manpages installed on this vault — man ssh, man sshd_config,
# man ssh-keygen are the right thing to have when you're debugging an outbound
# SSH key setup at 2am.
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get -y autoremove
  apt-get -y clean
'

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
# $ADMIN_USER in 30-vault is expanded on the HOST before pct exec; inside the
# quoted heredoc nothing further is expanded by the CT-side shell.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'EOF2'
#!/bin/sh
printf '\n  Vault LXC\n'
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

  cat > /etc/update-motd.d/30-vault <<'EOF2'
#!/bin/sh
printf '\n'
printf '  Vault key helper:\n'
printf '    su - $ADMIN_USER\n'
printf '    vault-key help\n'
printf '    vault-key add cloud-example 203.0.113.10 debian\n'
printf '    vault-key export cloud-example\n'
printf '    vault-key list\n'
printf '\n'
printf '  Inbound SSH stays locked until you add a key to:\n'
printf '    /home/$ADMIN_USER/.ssh/authorized_keys\n'
EOF2

  cat > /etc/update-motd.d/99-footer <<'EOF2'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
EOF2

  chmod +x /etc/update-motd.d/*
"

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
VAULT_DESC="Vault LXC (${CT_IP}) — ssh ${ADMIN_USER}@${CT_IP} -p ${SSH_PORT}
<details><summary>Details</summary>Debian ${DEBIAN_VERSION} SSH vault
Admin user: ${ADMIN_USER}
SSH port: ${SSH_PORT}
Inbound SSH locked until key added to /home/${ADMIN_USER}/.ssh/authorized_keys
Key helper inside CT: ${VAULT_HELPER_PATH}
Created by vault-lxc.sh</details>"
pct set "$CT_ID" --description "$VAULT_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Host tmpdir cleanup (success path) ────────────────────────────────────────
rm -rf "$HOST_TMPDIR"
unset HOST_TMPDIR

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  Done."
echo "  CT ID:        $CT_ID"
echo "  CT IP:        $CT_IP"
echo "  Admin user:   $ADMIN_USER"
echo "  SSH port:     $SSH_PORT"
echo "  Root locked:  $([ "$LOCK_ROOT_PASSWORD" -eq 1 ] && echo yes || echo no)"
echo "  Key helper:   $VAULT_HELPER_PATH (inside CT)"
echo ""
echo "  Inbound SSH to this vault CT is locked until a public key is added to:"
echo "    /home/$ADMIN_USER/.ssh/authorized_keys"
echo ""
echo "  Next steps:"
echo "    1) pct enter $CT_ID"
echo "    2) su - $ADMIN_USER"
echo "    3) Paste an inbound login key into ~/.ssh/authorized_keys"
echo "    4) vault-key add cloud-example 203.0.113.10 debian"
echo "    5) vault-key export cloud-example"
echo ""
