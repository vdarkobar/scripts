#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="unbound"
CPU=4
RAM=4096
DISK=4
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Unbound
UB_TZ="Europe/Berlin"
UB_DOMAIN=""                # auto-detect from CT resolv.conf, or set manually
TAGS="unbound;dns;lxc"
DEBIAN_VERSION=13

# Post-install: edit these drop-in files inside the CT for your network
#   /etc/unbound/unbound.conf.d/vlans.conf           VLAN access control
#   /etc/unbound/unbound.conf.d/30-static-hosts.conf Static DNS records (A + PTR)
# Then reload: pct exec <CT_ID> -- systemctl reload unbound

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging

# ── Trap cleanup ──────────────────────────────────────────────────────────────
trap 'trap - ERR; rc=$?;
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

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }

# ── Show defaults & confirm ──────────────────────────────────────────────────
cat <<EOF

  Unbound DNS LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU:               $CPU core(s)
  RAM:               $RAM MiB
  Disk:              $DISK GB
  Bridge:            $BRIDGE
  Template Storage:  $TEMPLATE_STORAGE
  Container Storage: $CONTAINER_STORAGE
  Debian Version:    $DEBIAN_VERSION
  Timezone:          $UB_TZ
  Domain:            ${UB_DOMAIN:-"(auto-detect)"}
  Tags:              $TAGS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF
read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *) echo "  Cancelled."; exit 0 ;;
esac
echo ""

# ── Validate storage & network ───────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }

pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }

ip link show "$BRIDGE" >/dev/null 2>&1 || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

# ── Root password ────────────────────────────────────────────────────────────
PASSWORD=""
while true; do
  read -r -s -p "  Set root password (blank = auto-login): " PW1; echo
  [[ -z "$PW1" ]] && break
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 5 ]]; then echo "  Password must be at least 5 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done
echo ""

if [[ -z "$PASSWORD" ]]; then
  echo "  WARNING: Blank password enables root auto-login on the Proxmox console."
  echo ""
fi

# ── Template ─────────────────────────────────────────────────────────────────
pveam update
echo ""
[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }

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

# ── Create LXC ───────────────────────────────────────────────────────────────
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
)
[[ -n "$PASSWORD" ]] && PCT_OPTIONS+=(-password "$PASSWORD")

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

# ── Start & wait for IPv4 ───────────────────────────────────────────────────
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

# ── Auto-login if no password ────────────────────────────────────────────────
if [[ -z "$PASSWORD" ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    mkdir -p /etc/systemd/system/container-getty@1.service.d
    cat > /etc/systemd/system/container-getty@1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF
    systemctl daemon-reload
    systemctl restart container-getty@1.service
  '
fi

# ── OS update ────────────────────────────────────────────────────────────────
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

# ── Configure locale ─────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y locales
  sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
'

# ── Remove unnecessary services ──────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now ssh 2>/dev/null || true
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y openssh-server postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Set timezone ─────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  ln -sf /usr/share/zoneinfo/${UB_TZ} /etc/localtime
  echo '${UB_TZ}' > /etc/timezone
"

# ── Detect domain name (inside CT) ──────────────────────────────────────────
if [[ -z "$UB_DOMAIN" ]]; then
  UB_DOMAIN="$(pct exec "$CT_ID" -- sh -lc "
    awk '/^domain/ {print \$2; exit}' /etc/resolv.conf 2>/dev/null || true
  " 2>/dev/null || true)"
fi
if [[ -z "$UB_DOMAIN" ]]; then
  UB_DOMAIN="$(pct exec "$CT_ID" -- sh -lc "
    awk '/^search/ {print \$2; exit}' /etc/resolv.conf 2>/dev/null || true
  " 2>/dev/null || true)"
fi
if [[ -z "$UB_DOMAIN" ]]; then
  read -r -p "  Could not detect domain. Enter local domain (e.g. home.local): " UB_DOMAIN
  [[ -n "$UB_DOMAIN" ]] || { echo "  ERROR: Domain name is required." >&2; exit 1; }
fi
echo "  Domain: $UB_DOMAIN"

# ── Install Unbound ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unbound dnsutils dns-root-data wget
'

# ── Update root hints (atomic) ──────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  tmp="$(mktemp)"
  if wget -qO "$tmp" https://www.internic.net/domain/named.root && test -s "$tmp"; then
    install -m 0644 "$tmp" /usr/share/dns/root.hints
  else
    echo "  WARNING: Failed to update root hints (using existing)"
  fi
  rm -f "$tmp"
'

# ── Write unbound.conf ──────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /etc/unbound/unbound.conf <<'UNBOUND_CONF'
# Unbound configuration file for Debian.
#
# See the unbound.conf(5) man page.
#
# See /usr/share/doc/unbound/examples/unbound.conf for a commented
# reference config file.
#
# The following line includes additional configuration files from the
# /etc/unbound/unbound.conf.d directory.

include-toplevel: \"/etc/unbound/unbound.conf.d/*.conf\"

# ============================================================================
#                         Static DNS host records
# ----------------------------------------------------------------------------
# All local A and PTR records are maintained in:
#
#             /etc/unbound/unbound.conf.d/30-static-hosts.conf
#
# Do NOT add local-data entries in this file.
# Modify the file above instead.
#
# ============================================================================
# Authoritative, validating, recursive caching DNS with DNS-Over-TLS support
# ============================================================================
server:

    # ------------------------------------------------------------------------
    # Runtime environment
    # ------------------------------------------------------------------------

    # Limit permissions
    username: \"unbound\"

    # Working directory
    directory: \"/etc/unbound\"

    # Chain of Trust (system CA bundle for DNS-over-TLS upstream validation)
    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt


    # ------------------------------------------------------------------------
    # Privacy
    # ------------------------------------------------------------------------

    # Send minimal amount of information to upstream servers to enhance privacy
    qname-minimisation: yes


    # ------------------------------------------------------------------------
    # Centralized logging
    # ------------------------------------------------------------------------

    use-syslog: yes
    # Increase to get more logging.
    verbosity: 1
    # For every user query that fails a line is printed
    val-log-level: 1
    # Logging of DNS queries
    log-queries: no


    # ------------------------------------------------------------------------
    # Root trust and DNSSEC
    # ------------------------------------------------------------------------

    # Root hints (note: unused when forwarding \".\"; kept as reference/fallback)
    root-hints: /usr/share/dns/root.hints
    harden-dnssec-stripped: yes


    # ------------------------------------------------------------------------
    # Network interfaces
    # ------------------------------------------------------------------------

    # Listen on all interfaces, answer queries from allowed subnets (ACLs below)
    interface: 0.0.0.0
    # interface: ::0

    do-ip4: yes
    do-ip6: no
    # do-ip6: yes
    do-udp: yes
    do-tcp: yes


    # ------------------------------------------------------------------------
    # Ports
    # ------------------------------------------------------------------------

    # Standard DNS
    port: 53

    # Local DNS-over-TLS port (for clients to unbound, only useful if you configure server cert/key)
    # tls-port: 853


    # ------------------------------------------------------------------------
    # Upstream communication
    # ------------------------------------------------------------------------

    # Use TCP connections for all upstream communications
    # when using DNS-over-TLS, otherwise default (no)
    tcp-upstream: yes


    # ------------------------------------------------------------------------
    # Cache behaviour
    # ------------------------------------------------------------------------

    # Perform prefetching of almost expired DNS cache entries.
    prefetch: yes

    # Serve expired cache entries if upstream DNS is temporarily unreachable
    # (RFC 8767 – improves resilience during ISP / upstream outages)
    serve-expired: yes
    serve-expired-ttl: 3600

    # Enable DNS cache (TTL limits)
    cache-max-ttl: 14400
    cache-min-ttl: 1200


    # ------------------------------------------------------------------------
    # Unbound privacy and security
    # ------------------------------------------------------------------------

    aggressive-nsec: yes
    hide-identity: yes
    hide-version: yes
    use-caps-for-id: yes


    # =========================================================================
    # Define Private Network and Access Control Lists (ACLs)
    # =========================================================================

    # Define private address ranges (RFC1918/ULA/link-local)
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    # private-address: fd00::/8
    # private-address: fe80::/10


    # ------------------------------------------------------------------------
    # Control which clients are allowed to make (recursive) queries
    # ------------------------------------------------------------------------

    # Administrative access (localhost only)
    access-control: 127.0.0.1/32 allow_snoop
    # access-control: ::1/128 allow_snoop

    # Normal DNS access from loopback
    access-control: 127.0.0.0/8 allow
    # access-control: ::1/128 allow


    # ------------------------------------------------------------------------
    # UniFi networks (VLAN's)
    # ------------------------------------------------------------------------

    # data located > /etc/unbound/unbound.conf.d/vlans.conf


    # ------------------------------------------------------------------------
    # Default deny (critical)
    # ------------------------------------------------------------------------

    access-control: 0.0.0.0/0 refuse
    # access-control: ::0/0 refuse


    # =========================================================================
    # Setup Local Domain
    # =========================================================================

    # Internal DNS namespace
    private-domain: \"__DOMAIN__\"

    # Local authoritative zone
    local-zone: \"__DOMAIN__.\" static

    # A Records Local

    # data located > /etc/unbound/unbound.conf.d/30-static-hosts.conf

    # =========================================================================
    # Reverse DNS (per VLAN / subnet)
    # =========================================================================
    # Define reverse zones for each VLAN subnet so PTR answers are authoritative.
    # PTR records are defined using local-data-ptr (simple and readable).

    # Reverse zones for /24 networks *(don't change: in-addr.arpa.)

    # data located in > /etc/unbound/unbound.conf.d/30-static-hosts.conf

    # Reverse Lookups Local (PTR records)

    # data located in > /etc/unbound/unbound.conf.d/30-static-hosts.conf


    # =========================================================================
    # Unbound Performance Tuning and Tweak
    # =========================================================================

    num-threads: 4
    msg-cache-slabs: 8
    rrset-cache-slabs: 8
    infra-cache-slabs: 8
    key-cache-slabs: 8
    rrset-cache-size: 256m
    msg-cache-size: 128m
    so-rcvbuf: 8m


# ============================================================================
# Use DNS over TLS (Upstream Forwarding)
# ============================================================================
forward-zone:
    name: \".\"
    forward-tls-upstream: yes

    # Quad9 DNS
    forward-addr: 9.9.9.9@853#dns.quad9.net
    forward-addr: 149.112.112.112@853#dns.quad9.net
    # forward-addr: 2620:fe::11@853#dns.quad9.net
    # forward-addr: 2620:fe::fe:11@853#dns.quad9.net

    # Quad9 DNS (Malware Blocking + Privacy) slower
    # forward-addr: 9.9.9.11@853#dns11.quad9.net
    # forward-addr: 149.112.112.11@853#dns11.quad9.net
    # forward-addr: 2620:fe::11@853#dns11.quad9.net
    # forward-addr: 2620:fe::fe:11@853#dns11.quad9.net

    # Cloudflare DNS
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
    # forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
    # forward-addr: 2606:4700:4700::1001@853#cloudflare-dns.com

    # Cloudflare DNS (Malware Blocking) slower
    # forward-addr: 1.1.1.2@853#cloudflare-dns.com
    # forward-addr: 2606:4700:4700::1112@853#cloudflare-dns.com
    # forward-addr: 1.0.0.2@853#cloudflare-dns.com
    # forward-addr: 2606:4700:4700::1002@853#cloudflare-dns.com

    # Google
    # forward-addr: 8.8.8.8@853#dns.google
    # forward-addr: 8.8.4.4@853#dns.google
    # forward-addr: 2001:4860:4860::8888@853#dns.google
    # forward-addr: 2001:4860:4860::8844@853#dns.google
UNBOUND_CONF
"

# Replace domain placeholder
pct exec "$CT_ID" -- sed -i "s/__DOMAIN__/${UB_DOMAIN}/g" /etc/unbound/unbound.conf

# ── Create drop-in: vlans.conf ───────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/unbound/unbound.conf.d
  cat > /etc/unbound/unbound.conf.d/vlans.conf <<VLANS
# VLAN access-control and reverse zones for Unbound
# Uncomment and adjust subnets for your network, then reload:
#   systemctl reload unbound
#
# Each VLAN that should query this DNS server needs an access-control
# line and (for /24 networks) a reverse zone for PTR lookups.

server:

    # ------------------------------------------------------------------------
    # VLAN networks - allowed to query this DNS server
    # ------------------------------------------------------------------------

    # access-control: 192.168.1.0/24 allow    # Main LAN
    # access-control: 192.168.20.0/24 allow   # IoT VLAN
    # access-control: 192.168.30.0/24 allow   # Guest VLAN
    # access-control: 10.10.0.0/24 allow      # Management VLAN

    # ------------------------------------------------------------------------
    # Reverse zones for /24 networks
    # ------------------------------------------------------------------------

    # local-zone: "1.168.192.in-addr.arpa." static      # Main LAN
    # local-zone: "20.168.192.in-addr.arpa." static     # IoT VLAN
    # local-zone: "30.168.192.in-addr.arpa." static     # Guest VLAN
    # local-zone: "10.10.10.in-addr.arpa." static       # Management VLAN
VLANS
'

# ── Create drop-in: 30-static-hosts.conf ────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /etc/unbound/unbound.conf.d/30-static-hosts.conf <<HOSTS
# Static DNS host records (A + PTR) for Unbound
# Domain: ${UB_DOMAIN}
# Uncomment and adjust for your infrastructure, then reload:
#   systemctl reload unbound
#
# Format:
#   local-data: \"hostname.${UB_DOMAIN}. IN A <ip>\"
#   local-data-ptr: \"<ip> hostname.${UB_DOMAIN}\"

server:

    # =========================================================================
    # Subnet: 192.168.1.0/24  (example — adjust to your network)
    # =========================================================================

    # local-data: \"proxmox.${UB_DOMAIN}. IN A 192.168.1.10\"
    # local-data-ptr: \"192.168.1.10 proxmox.${UB_DOMAIN}\"

    # local-data: \"nas.${UB_DOMAIN}. IN A 192.168.1.20\"
    # local-data-ptr: \"192.168.1.20 nas.${UB_DOMAIN}\"

    # local-data: \"printer.${UB_DOMAIN}. IN A 192.168.1.30\"
    # local-data-ptr: \"192.168.1.30 printer.${UB_DOMAIN}\"
HOSTS
"

# ── Validate config ─────────────────────────────────────────────────────────
if pct exec "$CT_ID" -- unbound-checkconf /etc/unbound/unbound.conf >/dev/null 2>&1; then
  echo "  Configuration validation passed"
else
  echo "  WARNING: Configuration validation had warnings (may still work)"
fi

# ── Cron: quarterly root hints update (atomic) ─────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  ( crontab -l 2>/dev/null || true
    echo ""
    echo "# Update root hints and reload unbound (quarterly)"
    echo "0 0 1 */3 * tmp=\$(mktemp) && wget -qO \"\$tmp\" https://www.internic.net/domain/named.root && test -s \"\$tmp\" && install -m 0644 \"\$tmp\" /usr/share/dns/root.hints && rm -f \"\$tmp\" && systemctl reload unbound"
  ) | crontab -
'

# ── Start service ────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  systemctl enable unbound
  systemctl restart unbound
'
sleep 2

# ── Persist DNS settings via Proxmox (CT will use itself on boot) ────────────
pct set "$CT_ID" --nameserver 127.0.0.1 --searchdomain "$UB_DOMAIN"

# Apply immediately (pct set only takes effect on next boot)
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
domain ${UB_DOMAIN}
search ${UB_DOMAIN}
EOF
"

# ── Prevent DHCP from overriding DNS settings ───────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/dhcp
  cat > /etc/dhcp/dhclient.conf <<EOF
# Unbound DNS container - ignore DHCP DNS from router
supersede domain-name-servers 127.0.0.1;
supersede domain-name \"${UB_DOMAIN}\";
supersede domain-search \"${UB_DOMAIN}\";
EOF
"

# Health check — verify Unbound answers queries
UB_HEALTHY=0
for i in $(seq 1 15); do
  if pct exec "$CT_ID" -- dig @127.0.0.1 google.com +short +time=2 +tries=1 >/dev/null 2>&1; then
    UB_HEALTHY=1
    break
  fi
  sleep 1
done

if [[ "$UB_HEALTHY" -eq 1 ]]; then
  echo "  Unbound is resolving queries"
else
  echo "  WARNING: Unbound not responding yet — service may still be initializing." >&2
  echo "  Check manually: pct enter $CT_ID -> dig @127.0.0.1 google.com" >&2
  pct exec "$CT_ID" -- journalctl -u unbound --no-pager -n 20 >&2 || true
fi

# ── Unattended upgrades (do NOT overwrite Debian defaults) ──────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades

  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat > /etc/apt/apt.conf.d/52unattended-unbound.conf <<EOF
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
EOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  systemctl enable --now unattended-upgrades
'

# ── Sysctl hardening ────────────────────────────────────────────────────────
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

# ── Cleanup unnecessary packages ────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
'

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'MOTD'
#!/bin/sh
printf '\n  Unbound DNS Resolver (DNS-over-TLS)\n'
printf '  ────────────────────────────────────\n'
MOTD

  cat > /etc/update-motd.d/10-sysinfo <<'MOTD'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' \"\$(hostname)\"
printf '  IP:        %s\n' \"\${ip:-n/a}\"
printf '  Uptime:   %s\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
MOTD

  cat > /etc/update-motd.d/30-app <<'MOTD'
#!/bin/sh
if systemctl is-active --quiet unbound 2>/dev/null; then
  printf '  Unbound:   running\n'
else
  printf '  Unbound:   stopped\n'
fi
printf '  Config:    /etc/unbound/unbound.conf\n'
printf '  VLANs:     /etc/unbound/unbound.conf.d/vlans.conf\n'
printf '  Hosts:     /etc/unbound/unbound.conf.d/30-static-hosts.conf\n'
printf '  Reload:    systemctl reload unbound\n'
printf '  Test:      dig google.com\n'
MOTD

  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD

  chmod +x /etc/update-motd.d/*
"

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ──────────────────────────────────────────────────
UB_DESC="Unbound DNS (${CT_IP})
<details><summary>Details</summary>Unbound DNS Resolver (DNS-over-TLS) on Debian ${DEBIAN_VERSION} LXC
Domain: ${UB_DOMAIN}
Created by unbound-lxc.sh</details>"
pct set "$CT_ID" --description "$UB_DESC"

# ── Protect container ───────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "CT: $CT_ID | IP: ${CT_IP} | DNS: ${CT_IP}:53 | Domain: ${UB_DOMAIN} | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'auto-login')"
echo ""

# ── Reboot CT so all DNS settings take effect cleanly ────────────────────────
echo "  Rebooting container..."
pct reboot "$CT_ID"
echo "  Done."
echo ""