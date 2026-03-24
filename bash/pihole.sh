#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="pihole"
CPU=1
RAM=512
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Pi-hole
APP_TZ="Europe/Berlin"
TAGS="pihole;dns;lxc"
# Debian 13 (Trixie) is supported since Pi-hole v6 Feb 2026 release; check
# current Pi-hole release notes for any active Trixie-specific issues.
DEBIAN_VERSION=13

# Upstream resolvers — used when FORWARD_TO_UNBOUND=0
# Pi-hole will forward queries to these after ad-filtering
DNS_UPSTREAM_1="9.9.9.9"             # Quad9 primary
DNS_UPSTREAM_2="149.112.112.112"     # Quad9 secondary
# Alternatives (uncomment to use):
# DNS_UPSTREAM_1="1.1.1.1"           # Cloudflare primary
# DNS_UPSTREAM_2="1.0.0.1"           # Cloudflare secondary
# DNS_UPSTREAM_1="8.8.8.8"           # Google primary
# DNS_UPSTREAM_2="8.8.4.4"           # Google secondary

# Optional: forward to your Unbound CT instead of public resolvers
# When enabled, UNBOUND_IP overrides both DNS_UPSTREAM_* values above
FORWARD_TO_UNBOUND=0                  # 1 = use Unbound CT as upstream
UNBOUND_IP=""                         # Set to Unbound CT IP, e.g. "192.168.1.10"

# Pi-hole settings
PUBLIC_FQDN=""                        # e.g. "pihole.example.com" ; blank = local IP only
PIHOLE_QUERY_LOGGING="true"           # "true" or "false"
PIHOLE_BLOCKING_ENABLED="true"        # "true" or "false"
PIHOLE_CACHE_SIZE=10000               # DNS cache entries (positive integer)
# Note: Pi-hole v6 web UI port is managed via /etc/pihole/pihole.toml after
# install (webserver.port). Default: HTTP 80, HTTPS 443 with self-signed cert.
# Do not attempt to set it here.

# Behavior
DISABLE_IPV6=1                        # 1 = disable IPv6 in sysctl
CLEANUP_ON_FAIL=1                     # 1 = destroy CT on error, 0 = keep for debugging

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/pihole/setupVars.conf        (unattended install answers)
#   /etc/pihole/pihole.toml           (Pi-hole v6 runtime config — written by installer)
#   /etc/systemd/resolved.conf.d/nostub.conf  (disables resolved stub on port 53)
#   /etc/dhcp/dhclient.conf           (prevent DHCP from overriding DNS)
#   /usr/local/bin/pihole-maint.sh    (maintenance helper)
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf

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

# ── Config validation ─────────────────────────────────────────────────────────
[[ "$DISABLE_IPV6" =~ ^[01]$ ]] \
  || { echo "  ERROR: DISABLE_IPV6 must be 0 or 1." >&2; exit 1; }
[[ "$FORWARD_TO_UNBOUND" =~ ^[01]$ ]] \
  || { echo "  ERROR: FORWARD_TO_UNBOUND must be 0 or 1." >&2; exit 1; }
[[ "$CPU" =~ ^[1-9][0-9]*$ ]] \
  || { echo "  ERROR: CPU must be a positive integer." >&2; exit 1; }
[[ "$RAM" =~ ^[1-9][0-9]*$ ]] \
  || { echo "  ERROR: RAM must be a positive integer (MiB)." >&2; exit 1; }
[[ "$DISK" =~ ^[1-9][0-9]*$ ]] \
  || { echo "  ERROR: DISK must be a positive integer (GB)." >&2; exit 1; }
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] \
  || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }
[[ "$PIHOLE_QUERY_LOGGING" =~ ^(true|false)$ ]] \
  || { echo "  ERROR: PIHOLE_QUERY_LOGGING must be 'true' or 'false'." >&2; exit 1; }
[[ "$PIHOLE_BLOCKING_ENABLED" =~ ^(true|false)$ ]] \
  || { echo "  ERROR: PIHOLE_BLOCKING_ENABLED must be 'true' or 'false'." >&2; exit 1; }
[[ "$PIHOLE_CACHE_SIZE" =~ ^[1-9][0-9]*$ ]] \
  || { echo "  ERROR: PIHOLE_CACHE_SIZE must be a positive integer." >&2; exit 1; }
[[ -e "/usr/share/zoneinfo/${APP_TZ}" ]] \
  || { echo "  ERROR: APP_TZ not found in /usr/share/zoneinfo: $APP_TZ" >&2; exit 1; }
if [[ -n "$PUBLIC_FQDN" && ! "$PUBLIC_FQDN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "  ERROR: PUBLIC_FQDN contains invalid characters: $PUBLIC_FQDN" >&2; exit 1
fi

if [[ "$FORWARD_TO_UNBOUND" -eq 1 ]]; then
  [[ -n "$UNBOUND_IP" ]] \
    || { echo "  ERROR: FORWARD_TO_UNBOUND=1 requires UNBOUND_IP to be set." >&2; exit 1; }
  [[ "$UNBOUND_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || { echo "  ERROR: UNBOUND_IP is not a valid IPv4 address: $UNBOUND_IP" >&2; exit 1; }
  DNS_UPSTREAM_1="$UNBOUND_IP"
  DNS_UPSTREAM_2="$UNBOUND_IP"
fi

[[ "$DNS_UPSTREAM_1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
  || { echo "  ERROR: DNS_UPSTREAM_1 is not a valid IPv4 address: $DNS_UPSTREAM_1" >&2; exit 1; }
[[ "$DNS_UPSTREAM_2" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
  || { echo "  ERROR: DNS_UPSTREAM_2 is not a valid IPv4 address: $DNS_UPSTREAM_2" >&2; exit 1; }

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct curl python3 ip awk sort paste; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }

if [[ "$DEBIAN_VERSION" -ge 13 ]]; then
  PVC_VER="$(dpkg-query -W -f='${Version}' pve-container 2>/dev/null | cut -d. -f1-2 || echo "0.0")"
  if dpkg --compare-versions "$PVC_VER" lt "5.3"; then
    echo "  ERROR: pve-container $PVC_VER is too old for Debian 13 templates." >&2
    echo "  Fix:   apt install --only-upgrade pve-container" >&2
    exit 1
  fi
fi

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"

if [[ "$FORWARD_TO_UNBOUND" -eq 1 ]]; then
  DNS_DISPLAY="Unbound CT (${UNBOUND_IP})"
else
  DNS_DISPLAY="${DNS_UPSTREAM_1} / ${DNS_UPSTREAM_2}"
fi

# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF

  Pi-hole DNS LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU:               $CPU core(s)
  RAM:               $RAM MiB
  Disk:              $DISK GB
  Bridge:            $BRIDGE ($AVAIL_BRIDGES)
  Template Storage:  $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container Storage: $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  Debian Version:    $DEBIAN_VERSION
  Timezone:          $APP_TZ
  Public FQDN:       ${PUBLIC_FQDN:-"(not set)"}
  Upstream DNS:      $DNS_DISPLAY
  Query logging:     $PIHOLE_QUERY_LOGGING
  Blocking:          $PIHOLE_BLOCKING_ENABLED
  Cache size:        $PIHOLE_CACHE_SIZE
  Tags:              $TAGS
  Disable IPv6:      $DISABLE_IPV6
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF

SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/pihole.sh"
SCRIPT_LOCAL="/root/pihole.sh"

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Saving script to ${SCRIPT_LOCAL} for editing..."
    if [[ -f "$SCRIPT_SELF" ]] && cp -f -- "$SCRIPT_SELF" "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
      echo "  Edit:  nano ${SCRIPT_LOCAL}"
      echo "  Run:   bash ${SCRIPT_LOCAL}"
      echo ""
    elif curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
      echo "  (downloaded from GitHub — local copy was not available)"
      echo "  Edit:  nano ${SCRIPT_LOCAL}"
      echo "  Run:   bash ${SCRIPT_LOCAL}"
      echo ""
    else
      echo "  ERROR: Could not save script for editing." >&2
    fi
    exit 0
    ;;
esac
echo ""

# ── Preflight — environment ───────────────────────────────────────────────────
pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "
import sys, json
stores = [s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content','')]
exit(0 if '${TEMPLATE_STORAGE}' in stores else 1)
" || { echo "  ERROR: $TEMPLATE_STORAGE does not support vztmpl content." >&2; exit 1; }

pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "
import sys, json
stores = [s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content','')]
exit(0 if '${CONTAINER_STORAGE}' in stores else 1)
" || { echo "  ERROR: $CONTAINER_STORAGE does not support rootdir content." >&2; exit 1; }

ip link show "$BRIDGE" >/dev/null 2>&1 || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password ─────────────────────────────────────────────────────────────
ROOT_PASSWORD=""
while true; do
  read -r -s -p "  Set root password (CT console): " PW1; echo
  if [[ -z "$PW1" ]]; then echo "  Password cannot be blank."; continue; fi
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then ROOT_PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done
echo ""

# ── Pi-hole admin password ────────────────────────────────────────────────────
PIHOLE_PASSWORD=""
while true; do
  read -r -s -p "  Set Pi-hole web UI password: " PW1; echo
  if [[ -z "$PW1" ]]; then echo "  Password cannot be blank."; continue; fi
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 8 ]]; then echo "  Password must be at least 8 characters."; continue; fi
  read -r -s -p "  Verify Pi-hole web UI password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PIHOLE_PASSWORD="$PW1"; break; fi
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
# Address stability is handled by a DHCP reservation at the network level.
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
  -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=manual"
  -password "$ROOT_PASSWORD"
)

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

# ── Start & wait for IPv4 ─────────────────────────────────────────────────────
pct start "$CT_ID"

CT_IP=""
for i in $(seq 1 30); do
  CT_IP="$(
    pct exec "$CT_ID" -- sh -lc '
      ip -4 -o addr show scope global 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -n1
    ' 2>/dev/null || true
  )"
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

# ── Remove unnecessary services ───────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Set timezone ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

# ── Install dependencies ──────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y curl ca-certificates dnsutils
'

# ── Disable systemd-resolved stub (frees port 53 for Pi-hole FTL) ─────────────
# Pi-hole FTL binds 0.0.0.0:53. The systemd-resolved stub listener at
# 127.0.0.53:53 conflicts. Disable the stub only; resolved keeps running for
# upstream DNS during the rest of the install. The CT switches to its own
# resolver only after all package work is complete.
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "  Disabling systemd-resolved stub listener..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/nostub.conf <<EOF
[Resolve]
DNSStubListener=no
EOF
    systemctl restart systemd-resolved
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    echo "  systemd-resolved stub disabled — port 53 is now free"
  else
    echo "  systemd-resolved not active — port 53 is already free"
  fi
'

# ── Write setupVars.conf for unattended Pi-hole install ───────────────────────
# Do not set PIHOLE_INTERFACE or DNSMASQ_LISTENING here. Forcing single-interface
# binding on eth0 causes "interface eth0 does not currently exist" warnings when
# FTL starts before DHCP completes. dns.listeningMode is set to LOCAL below.
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/pihole
  cat > /etc/pihole/setupVars.conf <<EOF
PIHOLE_DNS_1=${DNS_UPSTREAM_1}
PIHOLE_DNS_2=${DNS_UPSTREAM_2}
QUERY_LOGGING=${PIHOLE_QUERY_LOGGING}
INSTALL_WEB_INTERFACE=true
INSTALL_WEB_SERVER=true
LIGHTTPD_ENABLED=false
CACHE_SIZE=${PIHOLE_CACHE_SIZE}
BLOCKING_ENABLED=${PIHOLE_BLOCKING_ENABLED}
WEBUIBOXEDLAYOUT=boxed
WEBTHEME=default-dark
EOF
"

# ── Install Pi-hole ───────────────────────────────────────────────────────────
echo "  Downloading Pi-hole installer..."
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  curl -fsSL https://install.pi-hole.net -o /tmp/pihole_install.sh
  chmod +x /tmp/pihole_install.sh
'

echo "  Running Pi-hole installer (unattended)..."
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export PIHOLE_SKIP_OS_CHECK=false
  bash /tmp/pihole_install.sh --unattended
  rm -f /tmp/pihole_install.sh
'

# ── Set Pi-hole runtime interface config ──────────────────────────────────────
# LOCAL listening mode uses wildcard binding on local subnets — correct for a
# single-NIC LXC. SINGLE (the installer default when DNSMASQ_LISTENING=single
# is set) binds only to a named interface and triggers the eth0 warning if FTL
# starts before DHCP settles. Clearing dns.interface and setting LOCAL avoids
# this entirely. misc.delay_startup adds a small safety margin on boot.
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  pihole-FTL --config dns.interface ""
  pihole-FTL --config dns.listeningMode "LOCAL"
  pihole-FTL --config misc.delay_startup 5
'

# ── Disable Pi-hole built-in NTP client ──────────────────────────────────────
# Pi-hole v6 ships its own NTP client and attempts to set the system clock
# directly. Unprivileged LXC containers do not have CAP_SYS_TIME, so every
# sync attempt fails with "Insufficient permissions". Time is already kept
# correct by systemd-timesyncd via the Proxmox host — Pi-hole's NTP client
# is redundant and only produces noise in the diagnostics page.
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  pihole-FTL --config ntp.sync.active false
'

# ── Set Pi-hole web UI password ───────────────────────────────────────────────
# Write password via pct push to avoid shell quoting issues with special chars.
PIHOLE_PW_HOST="$(mktemp)"
printf '%s' "$PIHOLE_PASSWORD" > "$PIHOLE_PW_HOST"
pct push "$CT_ID" "$PIHOLE_PW_HOST" /tmp/.pihole_pw
rm -f "$PIHOLE_PW_HOST"
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  pihole setpassword "$(cat /tmp/.pihole_pw)"
  rm -f /tmp/.pihole_pw
'

# ── Maintenance helper ────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "cat > /usr/local/bin/pihole-maint.sh <<'MAINT'
#!/usr/bin/env bash
set -Eeo pipefail

# Persistent state preserved by pihole -up:
#   /etc/pihole/         pihole.toml, gravity.db, blocklists, setupVars.conf
#   /etc/dnsmasq.d/      Pi-hole-managed dnsmasq drop-ins
#
# Backup and restore are handled by PBS and PVE snapshots — not by this helper.

cmd=\"\${1:-}\"
case \"\$cmd\" in
  update)
    echo \"  Reminder: take a PVE snapshot before updating Pi-hole.\"
    read -r -p \"  Continue? [y/N]: \" yn
    case \"\$yn\" in [yY]*) ;; *) exit 0 ;; esac
    echo \"  Updating Pi-hole...\"
    pihole -up
    echo \"  Done.\"
    ;;
  gravity)
    echo \"  Updating gravity (blocklists)...\"
    pihole -g
    echo \"  Done.\"
    ;;
  version)
    pihole version
    ;;
  ''|-h|--help)
    echo \"Usage: \$0 update | gravity | version\"
    ;;
  *)
    echo \"  ERROR: Unknown command: \$cmd\" >&2
    exit 1
    ;;
esac
MAINT
chmod 0755 /usr/local/bin/pihole-maint.sh"

# ── Unattended upgrades ───────────────────────────────────────────────────────
# All remaining apt work runs while CT still uses DHCP DNS (not itself).
# The self-DNS switch happens after all package operations are complete.
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades

  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat > /etc/apt/apt.conf.d/52unattended-$(hostname).conf <<EOF
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
EOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  systemctl enable --now unattended-upgrades
'

# ── Sysctl hardening ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/sysctl.d/99-hardening.conf <<EOF
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
EOF
  sysctl --system >/dev/null 2>&1 || true
'

if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    cat >> /etc/sysctl.d/99-hardening.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl --system >/dev/null 2>&1 || true
  '
fi

# ── Cleanup packages ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
'

# ── Point CT at itself for DNS ────────────────────────────────────────────────
# All package work is complete. Switch DNS now.
# Note: once applied, DNS-dependent tools inside the CT (apt, curl) depend on
# pihole-FTL staying healthy. If FTL breaks, temporarily restore
# /etc/resolv.conf to an upstream resolver before running apt or curl.
pct set "$CT_ID" --nameserver 127.0.0.1

# Apply immediately (pct set only takes effect on next boot)
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
EOF
'

# ── Prevent DHCP from overriding DNS settings ─────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/dhcp
  cat > /etc/dhcp/dhclient.conf <<EOF
# Pi-hole DNS container — ignore DHCP nameservers from router
supersede domain-name-servers 127.0.0.1;
EOF
'

# ── Verification ──────────────────────────────────────────────────────────────
sleep 3

if pct exec "$CT_ID" -- systemctl is-active --quiet pihole-FTL 2>/dev/null; then
  echo "  pihole-FTL service is running"
else
  echo "  WARNING: pihole-FTL may not be running — check:" >&2
  echo "    pct exec $CT_ID -- journalctl -u pihole-FTL --no-pager -n 50" >&2
fi

# DNS health check — local FTL response (fatal: CT is now its own resolver)
DNS_LOCAL=0
for i in $(seq 1 15); do
  if pct exec "$CT_ID" -- dig @127.0.0.1 pi.hole +short +time=2 +tries=1 >/dev/null 2>&1; then
    DNS_LOCAL=1
    break
  fi
  sleep 1
done

if [[ "$DNS_LOCAL" -eq 1 ]]; then
  echo "  DNS local check passed (pi.hole resolves via 127.0.0.1)"
else
  echo "  ERROR: FTL not responding on 127.0.0.1:53 — cannot continue." >&2
  echo "  Check: pct exec $CT_ID -- journalctl -u pihole-FTL --no-pager -n 50" >&2
  exit 1
fi

# DNS health check — upstream forwarding
DNS_UPSTREAM_OK=0
for i in $(seq 1 10); do
  if pct exec "$CT_ID" -- dig @127.0.0.1 pi-hole.net +short +time=3 +tries=1 >/dev/null 2>&1; then
    DNS_UPSTREAM_OK=1
    break
  fi
  sleep 1
done

if [[ "$DNS_UPSTREAM_OK" -eq 1 ]]; then
  echo "  DNS upstream check passed (pi-hole.net resolves via FTL)"
else
  echo "  WARNING: Upstream DNS not resolving via FTL — check upstream setting." >&2
  echo "  Upstream configured: ${DNS_DISPLAY}" >&2
fi

# Web UI health check — HTTPS first (self-signed cert, use -k), then HTTP fallback.
# Pi-hole v6 default webserver.port serves both independently; HTTP does not
# automatically redirect to HTTPS unless explicitly configured in pihole.toml.
WEB_HEALTHY=0
WEB_PROTO=""
for i in $(seq 1 20); do
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc \
    "curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/admin/ 2>/dev/null" 2>/dev/null || echo "000")"
  if [[ "$HTTP_CODE" =~ ^(200|302|303)$ ]]; then
    WEB_HEALTHY=1
    WEB_PROTO="HTTPS"
    break
  fi
  HTTP_CODE="$(pct exec "$CT_ID" -- sh -lc \
    "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/admin/ 2>/dev/null" 2>/dev/null || echo "000")"
  if [[ "$HTTP_CODE" =~ ^(200|302|303)$ ]]; then
    WEB_HEALTHY=1
    WEB_PROTO="HTTP"
    break
  fi
  sleep 2
done

if [[ "$WEB_HEALTHY" -eq 1 ]]; then
  echo "  Web UI health check passed (${WEB_PROTO} — HTTP ${HTTP_CODE})"
else
  echo "  WARNING: Web UI not responding on port 443 or 80 yet" >&2
fi

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'MOTD'
#!/bin/sh
printf '\n  Pi-hole DNS Filter\n'
printf '  ────────────────────────────────────\n'
MOTD

  cat > /etc/update-motd.d/10-sysinfo <<'MOTD'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' \"\$(hostname)\"
printf '  IP:        %s\n' \"\${ip:-n/a}\"
printf '  Uptime:    %s\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
MOTD

  cat > /etc/update-motd.d/30-app <<'MOTD'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
if systemctl is-active --quiet pihole-FTL 2>/dev/null; then
  ftl_status='running'
else
  ftl_status='stopped'
fi
gravity_ts=\$(pihole status 2>/dev/null | grep -i 'gravity' | grep -oP '\d{4}-\d{2}-\d{2}' | head -n1 || echo 'unknown')
printf '\n'
printf '  Pi-hole:\n'
printf '    FTL service:     %s\n' \"\$ftl_status\"
printf '    Gravity updated: %s\n' \"\$gravity_ts\"
printf '    Web UI (HTTPS):  https://%s/admin/  (self-signed cert)\n' \"\${ip:-localhost}\"
printf '    Web UI (HTTP):   http://%s/admin/\n' \"\${ip:-localhost}\"
printf '    Config:          /etc/pihole/pihole.toml\n'
printf '\n'
printf '  Maintenance:\n'
printf '    pihole-maint.sh update\n'
printf '    pihole-maint.sh gravity\n'
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

# ── TERM fix ──────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
if [[ -n "$PUBLIC_FQDN" ]]; then
  PIHOLE_DESC="<a href='https://${PUBLIC_FQDN}/admin/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Pi-hole Web UI (public)</a> | <a href='https://${CT_IP}/admin/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Pi-hole Web UI (local)</a>
<details><summary>Details</summary>Pi-hole v6 DNS filter on Debian ${DEBIAN_VERSION} LXC
Public: https://${PUBLIC_FQDN}/admin/
Local:  https://${CT_IP}/admin/ (self-signed cert)
Upstream: ${DNS_DISPLAY}
Created by pihole.sh</details>"
else
  PIHOLE_DESC="<a href='https://${CT_IP}/admin/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Pi-hole Web UI</a>
<details><summary>Details</summary>Pi-hole v6 DNS filter on Debian ${DEBIAN_VERSION} LXC
Web UI (HTTPS): https://${CT_IP}/admin/ (self-signed cert)
Web UI (HTTP):  http://${CT_IP}/admin/
Upstream: ${DNS_DISPLAY}
Created by pihole.sh</details>"
fi
pct set "$CT_ID" --description "$PIHOLE_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  CT: $CT_ID | IP: ${CT_IP} | Login: password set"
echo ""
echo "  Access (local):"
echo "    Web UI:  https://${CT_IP}/admin/  (self-signed cert — accept browser warning)"
echo "    HTTP:    http://${CT_IP}/admin/"
echo "    DNS:     ${CT_IP}:53"
if [[ -n "$PUBLIC_FQDN" ]]; then
  echo ""
  echo "  Access (public):"
  echo "    Web UI:  https://${PUBLIC_FQDN}/admin/"
  echo "    DNS:     ${PUBLIC_FQDN}:53"
fi
echo ""
echo "  Note: HTTP and HTTPS are independent listeners by default."
echo "    To configure HTTP→HTTPS redirect, set webserver.port in pihole.toml."
echo ""
echo "  Upstream DNS:  ${DNS_DISPLAY}"
echo ""
echo "  DNS self-referral note:"
echo "    This CT uses itself as its DNS resolver. If pihole-FTL stops"
echo "    responding, apt and curl inside the CT will also fail. To recover:"
echo "    temporarily set /etc/resolv.conf to an upstream, fix FTL, restore."
echo ""
echo "  Config files:"
echo "    /etc/pihole/pihole.toml      (Pi-hole v6 runtime config)"
echo "    /etc/pihole/setupVars.conf   (install answers — reference only)"
echo ""
echo "  Maintenance:"
echo "    pct exec $CT_ID -- bash -lc 'pihole-maint.sh update'    (update Pi-hole)"
echo "    pct exec $CT_ID -- bash -lc 'pihole-maint.sh gravity'   (update blocklists)"
echo ""
echo "  Reload after config edits:"
echo "    pct exec $CT_ID -- bash -lc 'systemctl restart pihole-FTL'"
echo ""
echo "  Done."
echo ""
