#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="samba"
CPU=2
RAM=2048
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Samba
SMB_TZ="Europe/Berlin"
SMB_SHARE_NAME="Data"
SMB_SHARE_PATH="/srv/samba/Data"
SMB_GROUP="sambashare"
SMB_WORKGROUP="WORKGROUP"
SMB_SERVER_NAME="FILESERVER"
SMB_MIN_PROTOCOL="SMB3"
SMB_SERVER_SIGNING="mandatory"
SMB_ENCRYPTION="mandatory"
TAGS="samba;fileserver;lxc"
DEBIAN_VERSION=13

# Post-install: add more Samba users inside the CT
#   pct exec <CT_ID> -- useradd -M -s /usr/sbin/nologin -G sambashare <username>
#   pct exec <CT_ID> -- smbpasswd -a <username>
#   pct exec <CT_ID> -- smbpasswd -e <username>

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

  Samba File Server LXC Creator — Configuration
  ────────────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  CPU:               $CPU core(s)
  RAM:               $RAM MiB
  Disk:              $DISK GB
  Bridge:            $BRIDGE
  Template Storage:  $TEMPLATE_STORAGE
  Container Storage: $CONTAINER_STORAGE
  Debian Version:    $DEBIAN_VERSION
  Timezone:          $SMB_TZ
  Share Name:        $SMB_SHARE_NAME
  Share Path:        $SMB_SHARE_PATH
  Group:             $SMB_GROUP
  Workgroup:         $SMB_WORKGROUP
  Server Name:       $SMB_SERVER_NAME
  Min Protocol:      $SMB_MIN_PROTOCOL
  Server Signing:    $SMB_SERVER_SIGNING
  SMB Encryption:    $SMB_ENCRYPTION
  Tags:              $TAGS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────────────
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

# ── First Samba user ─────────────────────────────────────────────────────────
SMB_USER=""
SMB_USER_PASS=""
while true; do
  read -r -p "  Samba username (blank = skip): " SMB_USER
  [[ -z "$SMB_USER" ]] && break
  if [[ ! "$SMB_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "  Invalid: lowercase letters, numbers, underscore, dash only."
    SMB_USER=""
    continue
  fi
  while true; do
    read -r -s -p "  Samba password for $SMB_USER: " SP1; echo
    if [[ -z "$SP1" ]]; then echo "  Password cannot be blank."; continue; fi
    if [[ ${#SP1} -lt 5 ]]; then echo "  Password must be at least 5 characters."; continue; fi
    read -r -s -p "  Verify password: " SP2; echo
    if [[ "$SP1" == "$SP2" ]]; then SMB_USER_PASS="$SP1"; break; fi
    echo "  Passwords do not match. Try again."
  done
  break
done
echo ""

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
  ln -sf /usr/share/zoneinfo/${SMB_TZ} /etc/localtime
  echo '${SMB_TZ}' > /etc/timezone
"

# ── Install Samba ────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y samba samba-common-bin acl attr
'

# ── Harden system crypto policy ─────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /etc/gnutls
  cat > /etc/gnutls/config <<EOF
[global]
override-mode = blocklist

[overrides]
insecure-hash = SHA1
insecure-sig = RSA-SHA1
EOF
'

# ── Create group and share directory ─────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  
  # Create group
  if ! getent group '${SMB_GROUP}' >/dev/null 2>&1; then
    groupadd '${SMB_GROUP}'
  fi
  
  # Create share directory
  mkdir -p '${SMB_SHARE_PATH}'
  chown root:'${SMB_GROUP}' '${SMB_SHARE_PATH}'
  chmod 2775 '${SMB_SHARE_PATH}'
  
  # Set default ACLs
  setfacl -d -m 'g:${SMB_GROUP}:rwx' '${SMB_SHARE_PATH}' 2>/dev/null || true
  setfacl -d -m 'm:rwx' '${SMB_SHARE_PATH}' 2>/dev/null || true
"

# ── Write smb.conf ───────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  
  # Backup original
  [[ -f /etc/samba/smb.conf ]] && cp /etc/samba/smb.conf /etc/samba/smb.conf.orig
  
  cat > /etc/samba/smb.conf <<'SAMBA_CONF'
#======================= Global Settings =======================

[global]
   workgroup = __WORKGROUP__
   server string = Samba File Server %v
   netbios name = __SERVER_NAME__

   security = user
   passdb backend = tdbsam
   map to guest = never

   server min protocol = __MIN_PROTOCOL__
   client min protocol = __MIN_PROTOCOL__
   server signing = __SERVER_SIGNING__
   client signing = __SERVER_SIGNING__
   smb encrypt = __SMB_ENCRYPTION__
   server smb3 encryption algorithms = AES-256-GCM, AES-256-CCM
   server smb3 signing algorithms = AES-256-GMAC
   ntlm auth = ntlmv2-only

   log file = /var/log/samba/log.%m
   max log size = 5000
   log level = 1
   logging = syslog@1 file

   load printers = no
   printcap name = /dev/null
   disable spoolss = yes
   show add printer wizard = no

   dns proxy = no

   unix extensions = no
   follow symlinks = no
   wide links = no

#======================= Share Definitions =======================

[__SHARE_NAME__]
   comment = Shared Directory
   path = __SHARE_PATH__
   browseable = yes
   writable = yes
   guest ok = no
   valid users = @__GROUP__
   create mask = 0664
   directory mask = 2775
   force group = __GROUP__

   oplocks = yes
   level2 oplocks = yes

   vfs objects = acl_xattr
   inherit acls = yes
   inherit permissions = yes
   ea support = yes
   store dos attributes = yes
   map archive = no
   map hidden = no
   map readonly = no
   map system = no
SAMBA_CONF
"

# Replace placeholders
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  sed -i 's/__WORKGROUP__/${SMB_WORKGROUP}/g'     /etc/samba/smb.conf
  sed -i 's/__SERVER_NAME__/${SMB_SERVER_NAME}/g'  /etc/samba/smb.conf
  sed -i 's/__MIN_PROTOCOL__/${SMB_MIN_PROTOCOL}/g' /etc/samba/smb.conf
  sed -i 's/__SERVER_SIGNING__/${SMB_SERVER_SIGNING}/g' /etc/samba/smb.conf
  sed -i 's/__SMB_ENCRYPTION__/${SMB_ENCRYPTION}/g' /etc/samba/smb.conf
  sed -i 's/__SHARE_NAME__/${SMB_SHARE_NAME}/g'   /etc/samba/smb.conf
  sed -i 's|__SHARE_PATH__|${SMB_SHARE_PATH}|g'   /etc/samba/smb.conf
  sed -i 's/__GROUP__/${SMB_GROUP}/g'              /etc/samba/smb.conf
"

# ── Validate config ─────────────────────────────────────────────────────────
if pct exec "$CT_ID" -- testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
  echo "  Configuration validation passed"
else
  echo "  WARNING: Configuration validation had warnings (may still work)"
fi

# ── Start services ───────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /var/log/samba
  systemctl enable smbd
  systemctl restart smbd
'
sleep 2

# Verify smbd is running
if pct exec "$CT_ID" -- systemctl is-active --quiet smbd 2>/dev/null; then
  echo "  Samba service is running"
else
  echo "  WARNING: Samba service may not have started." >&2
  pct exec "$CT_ID" -- journalctl -u smbd --no-pager -n 20 >&2 || true
fi

# ── Create first Samba user ──────────────────────────────────────────────────
if [[ -n "$SMB_USER" ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    useradd -M -s /usr/sbin/nologin -G '${SMB_GROUP}' '${SMB_USER}'
    printf '%s\n%s\n' '${SMB_USER_PASS}' '${SMB_USER_PASS}' | smbpasswd -a -s '${SMB_USER}'
    smbpasswd -e '${SMB_USER}'
  "
  echo "  Samba user created: $SMB_USER"
fi

# ── Unattended upgrades ─────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y unattended-upgrades

  distro_codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat > /etc/apt/apt.conf.d/52unattended-samba.conf <<EOF
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security";
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

# ── MOTD ─────────────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > /etc/motd <<EOF

  Samba File Server (SMB3 encrypted)
  ────────────────────────────────────
  Config:   /etc/samba/smb.conf
  Share:    ${SMB_SHARE_PATH}
  Group:    ${SMB_GROUP}
  Validate: testparm -s
  Restart:  systemctl restart smbd

  Add user:
    useradd -M -s /usr/sbin/nologin -G ${SMB_GROUP} <user>
    smbpasswd -a <user>
    smbpasswd -e <user>

EOF
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
"

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ──────────────────────────────────────────────────
SMB_DESC="Samba File Server (${CT_IP})
<details><summary>Details</summary>Samba File Server (SMB3 encrypted) on Debian ${DEBIAN_VERSION} LXC
Share: ${SMB_SHARE_NAME} → ${SMB_SHARE_PATH}
Workgroup: ${SMB_WORKGROUP}
Created by samba-lxc.sh</details>"
pct set "$CT_ID" --description "$SMB_DESC"

# ── Protect container ───────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "CT: $CT_ID | IP: ${CT_IP} | SMB: \\\\${CT_IP}\\${SMB_SHARE_NAME} | User: ${SMB_USER:-none} | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'auto-login')"
echo ""
echo "  Add more Samba users:"
echo "    pct exec $CT_ID -- useradd -M -s /usr/sbin/nologin -G $SMB_GROUP <username>"
echo "    pct exec $CT_ID -- smbpasswd -a <username>"
echo "    pct exec $CT_ID -- smbpasswd -e <username>"
echo ""

# ── Reboot CT so all settings take effect cleanly ────────────────────────────
echo "  Rebooting container..."
pct reboot "$CT_ID"
echo "  Done."
echo ""
