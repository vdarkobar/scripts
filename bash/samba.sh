#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=120 to pin
HN="samba"
CPU=4
RAM=4096
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Samba
APP_TZ="Europe/Berlin"
SMB_SHARE_NAME="Data"
SMB_SHARE_PATH="/srv/samba/Data"
SMB_GROUP="sambashare"
SMB_WORKGROUP="WORKGROUP"
SMB_SERVER_NAME="FILESERVER"
SMB_MIN_PROTOCOL="SMB3_11"
SMB_SERVER_SIGNING="required"
SMB_ENCRYPTION="required"
TAGS="samba;fileserver;lxc"
DEBIAN_VERSION=13
SHARE_STORAGE="rootfs"              # rootfs | <zfs-pool-or-dataset> | /host/path
SHARE_DATASET_NAME=""               # ZFS mode only; empty = samba-<HN>. Named by hostname so a
                                    # rebuilt CT re-attaches its existing data automatically.
SMB_HOSTS_ALLOW=""                  # empty = unrestricted; e.g. "192.168.1.0/24" or "10.0.0.0/8 192.168.1.0/24"

# Post-install: add more Samba users inside the CT
#   pct exec <CT_ID> -- useradd -M -s /usr/sbin/nologin -G sambashare <username>
#   pct exec <CT_ID> -- smbpasswd -a <username>
#   pct exec <CT_ID> -- smbpasswd -e <username>

# Optional features
DISABLE_IPV6=0

# Extra packages to install inside the CT (leave empty for none)
EXTRA_PACKAGES=(
)

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/samba/smb.conf
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/apt/apt.conf.d/20auto-upgrades
#   /etc/sysctl.d/99-hardening.conf
#   <pool>/<SHARE_DATASET_NAME or samba-<HN>>                        (optional: ZFS dataset, when SHARE_STORAGE=<pool>)

# ── Validate config values (expanded into smb.conf / pct set) ────────────────
fail=""
[[ "$HN"                 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail="HN"
[[ "$APP_TZ"             =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || fail="APP_TZ"
[[ "$SMB_WORKGROUP"      =~ ^[A-Za-z0-9._-]+$ ]]     || fail="SMB_WORKGROUP"
[[ "$SMB_SERVER_NAME"    =~ ^[A-Za-z0-9._-]+$ ]]     || fail="SMB_SERVER_NAME"
[[ "$SMB_SHARE_NAME"     =~ ^[A-Za-z0-9_-]+$ ]]      || fail="SMB_SHARE_NAME"
[[ "$SMB_GROUP"          =~ ^[a-z_][a-z0-9_-]*$ ]]   || fail="SMB_GROUP"
[[ "$SMB_SHARE_PATH"     =~ ^/[A-Za-z0-9/_.-]+$ ]]   || fail="SMB_SHARE_PATH"
[[ "$SMB_MIN_PROTOCOL"   =~ ^[A-Za-z0-9_]+$ ]]       || fail="SMB_MIN_PROTOCOL"
[[ "$SMB_SERVER_SIGNING" =~ ^[a-z]+$ ]]              || fail="SMB_SERVER_SIGNING"
[[ "$SMB_ENCRYPTION"     =~ ^[a-z]+$ ]]              || fail="SMB_ENCRYPTION"
[[ "$SHARE_DATASET_NAME" =~ ^[A-Za-z0-9_.-]*$ ]]     || fail="SHARE_DATASET_NAME"
[[ "$SMB_HOSTS_ALLOW"    =~ ^[0-9A-Fa-f.:/,\ ]*$ ]]   || fail="SMB_HOSTS_ALLOW"
if [[ -n "$fail" ]]; then
  echo "  ERROR: Invalid characters in $fail — check the Config section." >&2
  exit 1
fi

if [[ "$SHARE_STORAGE" == /* ]]; then
  [[ "$SHARE_STORAGE" =~ ^/[A-Za-z0-9/_.-]+$ ]] \
    || { echo "  ERROR: SHARE_STORAGE host path contains invalid characters." >&2; exit 1; }
elif [[ "$SHARE_STORAGE" != "rootfs" && ! "$SHARE_STORAGE" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]]; then
  echo "  ERROR: SHARE_STORAGE must be rootfs, an absolute host path, or a ZFS pool/dataset name." >&2
  exit 1
fi

[[ -f "/usr/share/zoneinfo/${APP_TZ}" ]] \
  || { echo "  ERROR: Unknown timezone: ${APP_TZ}" >&2; exit 1; }

# ── Trap cleanup ──────────────────────────────────────────────────────────────
trap 'rc=$?; trap - ERR;
  echo "  ERROR: failed (rc=$rc) near line $LINENO" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
    if [[ -n "${SHARE_DATASET:-}" ]] && zfs list -H -o name "${SHARE_DATASET}" >/dev/null 2>&1; then
      echo "  Note: ZFS dataset ${SHARE_DATASET} was left in place (data is never auto-destroyed)." >&2
      echo "        Remove it manually if unwanted: zfs destroy ${SHARE_DATASET}" >&2
    fi
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
    if [[ -n "${SHARE_DATASET:-}" ]] && zfs list -H -o name "${SHARE_DATASET}" >/dev/null 2>&1; then
      echo "  Note: ZFS dataset ${SHARE_DATASET} was left in place (data is never auto-destroyed)." >&2
      echo "        Remove it manually if unwanted: zfs destroy ${SHARE_DATASET}" >&2
    fi
  fi
  exit "$rc"
' INT TERM

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }
[[ -t 0 ]] || { echo "  ERROR: stdin is not a terminal — run interactively, e.g. bash <(curl -fsSL URL), not curl | bash." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm curl python3 ip awk sort paste dpkg; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

if [[ -n "$CT_ID" ]]; then
  [[ "$CT_ID" =~ ^[0-9]+$ ]] && (( CT_ID >= 100 && CT_ID <= 999999999 )) \
    || { echo "  ERROR: CT_ID must be an integer >= 100." >&2; exit 1; }
  if pct status "$CT_ID" >/dev/null 2>&1 || qm status "$CT_ID" >/dev/null 2>&1; then
    echo "  ERROR: CT_ID $CT_ID is already in use on this node." >&2
    exit 1
  fi
else
  CT_ID="$(pvesh get /cluster/nextid)"
  [[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
fi

[[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || { echo "  ERROR: DEBIAN_VERSION must be numeric." >&2; exit 1; }

if [[ "$SHARE_STORAGE" != "rootfs" && "$SHARE_STORAGE" != /* ]]; then
  command -v zfs >/dev/null 2>&1 || { echo "  ERROR: zfs command is required when SHARE_STORAGE is a ZFS pool name." >&2; exit 1; }
fi

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_ZFS_POOLS="$(zpool list -H -o name 2>/dev/null | sort | paste -sd, - | sed 's/,/, /g' || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
if [[ "$SHARE_STORAGE" == "rootfs" ]]; then
  SHARE_DERIVED="inside CT rootfs: ${SMB_SHARE_PATH}"
elif [[ "$SHARE_STORAGE" == /* ]]; then
  SHARE_DERIVED="${SHARE_STORAGE} -> ${SMB_SHARE_PATH} (CT mp0)"
else
  SHARE_DERIVED="${SHARE_STORAGE}/${SHARE_DATASET_NAME:-samba-${HN}} -> ${SMB_SHARE_PATH} (CT mp0)"
fi

cat <<EOF

  Samba File Server LXC Creator — Configuration
  ────────────────────────────────────────────────
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
  Share Name:        $SMB_SHARE_NAME
  Share Path:        $SMB_SHARE_PATH
  Group:             $SMB_GROUP
  Workgroup:         $SMB_WORKGROUP
  Server Name:       $SMB_SERVER_NAME
  Min Protocol:      $SMB_MIN_PROTOCOL
  Server Signing:    $SMB_SERVER_SIGNING
  SMB Encryption:    $SMB_ENCRYPTION
  Share Storage:     $SHARE_STORAGE (available ZFS pools: $AVAIL_ZFS_POOLS)
  Derived:           $SHARE_DERIVED
  Hosts Allow:       ${SMB_HOSTS_ALLOW:-unrestricted}
  Tags:              $TAGS
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/samba.sh"
SCRIPT_LOCAL="/root/samba.sh"

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Downloading script to ${SCRIPT_LOCAL} for editing..."
    if curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_LOCAL"; then
      chmod +x "$SCRIPT_LOCAL"
      echo "  Edit:  nano ${SCRIPT_LOCAL}"
      echo "  Run:   bash ${SCRIPT_LOCAL}"
      echo ""
    else
      echo "  ERROR: Failed to download script." >&2
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

ip link show "$BRIDGE" >/dev/null 2>&1 || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }

if [[ "$SHARE_STORAGE" != "rootfs" && "$SHARE_STORAGE" != /* ]]; then
  zfs list -H -o name "$SHARE_STORAGE" >/dev/null 2>&1 \
    || { echo "  ERROR: ZFS pool/dataset not found: $SHARE_STORAGE (available: $AVAIL_ZFS_POOLS)" >&2; exit 1; }
fi

# ── Root password ─────────────────────────────────────────────────────────────
PASSWORD=""
while true; do
  read -r -s -p "  Set root password: " PW1; echo
  if [[ -z "$PW1" ]]; then echo "  Password cannot be blank."; continue; fi
  if [[ "$PW1" == *" "* ]]; then echo "  Password cannot contain spaces."; continue; fi
  if [[ ${#PW1} -lt 5 ]]; then echo "  Password must be at least 5 characters."; continue; fi
  read -r -s -p "  Verify root password: " PW2; echo
  if [[ "$PW1" == "$PW2" ]]; then PASSWORD="$PW1"; break; fi
  echo "  Passwords do not match. Try again."
done
echo ""

# ── First Samba user ──────────────────────────────────────────────────────────
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
  if [[ "$SMB_USER" == "root" ]]; then
    echo "  Invalid: root cannot be a Samba user."
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

# ── Template discovery & download ─────────────────────────────────────────────
pveam update
echo ""

# Filter by host architecture: the index lists amd64 and arm64 templates side by
# side, and "_arm64" sorts after "_amd64" — without this filter an x86 host picks
# the ARM template and the CT dies with "Exec format error" on /sbin/init.
HOST_ARCH="$(dpkg --print-architecture)"
TEMPLATE="$(pveam available -section system \
  | awk -v p="debian-${DEBIAN_VERSION}" -v a="_${HOST_ARCH}." '$2 ~ ("^" p) && index($2, a) {print $2}' \
  | sort -V | tail -n1)"
if [[ -z "$TEMPLATE" ]]; then
  echo "  WARNING: No Debian ${DEBIAN_VERSION} ${HOST_ARCH} template found, trying any Debian ${HOST_ARCH}..." >&2
  TEMPLATE="$(pveam available -section system \
    | awk -v a="_${HOST_ARCH}." '$2 ~ /^debian-/ && index($2, a) {print $2}' \
    | sort -V | tail -n1)"
fi
[[ -n "$TEMPLATE" ]] || { echo "  ERROR: No Debian template found via pveam." >&2; exit 1; }
echo "  Template: $TEMPLATE"

if pvesm list "$TEMPLATE_STORAGE" --content vztmpl 2>/dev/null | grep -qF "vztmpl/${TEMPLATE}"; then
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
  # nesting=1 is NOT for Samba: unprivileged CTs with systemd >= 255 (Debian 13 = 257)
  # need it to boot at all — PVE warns "You may need to enable nesting" without it.
  -features "nesting=1"
  -tags "$TAGS"
  -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=manual"
  -password "$PASSWORD"
)

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

# ── Share storage — ZFS dataset / bind-mount ──────────────────────────────────
if [[ "$SHARE_STORAGE" == "rootfs" ]]; then
  echo "  WARNING: No external share storage configured — share will use rootfs (${DISK} GB)." >&2
else
  if [[ "$SHARE_STORAGE" == /* ]]; then
    SHARE_HOST_PATH="$SHARE_STORAGE"
    mkdir -p "$SHARE_HOST_PATH"
  else
    SHARE_DATASET="${SHARE_STORAGE}/${SHARE_DATASET_NAME:-samba-${HN}}"
    SHARE_HOST_PATH="$(zfs get -H -o value mountpoint "${SHARE_DATASET}" 2>/dev/null || true)"
    if [[ -z "$SHARE_HOST_PATH" || "$SHARE_HOST_PATH" == "-" ]]; then
      echo "  Creating ZFS dataset: ${SHARE_DATASET}"
      # posixacl + xattr=sa: required for setfacl default ACLs and Samba DOS attributes
      zfs create \
        -o compression=lz4 \
        -o acltype=posixacl \
        -o xattr=sa \
        -o aclinherit=passthrough \
        "${SHARE_DATASET}"
      SHARE_HOST_PATH="$(zfs get -H -o value mountpoint "${SHARE_DATASET}")"
    elif [[ "$SHARE_HOST_PATH" == "legacy" || "$SHARE_HOST_PATH" == "none" ]]; then
      echo "  ERROR: ZFS dataset ${SHARE_DATASET} exists but has mountpoint=${SHARE_HOST_PATH}." >&2
      echo "         Set a real mountpoint (zfs set mountpoint=/path ${SHARE_DATASET}) or use another name." >&2
      false
    else
      echo "  Reusing existing ZFS dataset: ${SHARE_DATASET} -> ${SHARE_HOST_PATH}"
      [[ "$(zfs get -H -o value acltype "${SHARE_DATASET}")" == "posixacl" ]] \
        || echo "  WARNING: ${SHARE_DATASET} has acltype != posixacl — default ACLs will not apply." >&2
    fi
  fi

  # Unprivileged CT: CT root = host UID 100000. The mountpoint itself must be owned
  # by 100000 so the CT can chown/chmod it. Only the top directory is changed here —
  # existing files keep their host UIDs. Files written by a previous CT built with
  # this script already sit in the 100000+ range and remain usable. Anything else
  # must be fixed on the host afterwards, e.g.
  #   chown -R 100000:100000 <path>        (make everything CT-root owned), or
  #   chown -R 10XXXX:10YYYY <path>        (map to a specific CT uid/gid + 100000)
  if [[ -n "$(ls -A "$SHARE_HOST_PATH" 2>/dev/null)" ]]; then
    echo "  NOTE: ${SHARE_HOST_PATH} already contains data — keeping it." >&2
    echo "        Only the top directory is chowned to 100000:100000; existing files keep" >&2
    echo "        their current ownership (top dir now: $(stat -c '%u:%g' "$SHARE_HOST_PATH"))." >&2
  fi
  chown 100000:100000 "$SHARE_HOST_PATH"
  pct set "$CT_ID" --mp0 "${SHARE_HOST_PATH},mp=${SMB_SHARE_PATH}"
  echo "  Share mount: ${SHARE_HOST_PATH} -> ${SMB_SHARE_PATH} (CT ${CT_ID})"
fi

# ── Start & wait for IPv4 ─────────────────────────────────────────────────────
pct start "$CT_ID"

CT_IP=""
for i in $(seq 1 60); do
  CT_IP="$(
    pct exec "$CT_ID" -- sh -lc '
      ip -4 -o addr show scope global 2>/dev/null | awk "{print \$4}" | cut -d/ -f1 | head -n1
    ' 2>/dev/null || true
  )"
  [[ -n "$CT_IP" ]] && break
  sleep 1
done
[[ -n "$CT_IP" ]] || { echo "  ERROR: No IPv4 address acquired via DHCP within timeout." >&2; false; }

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
  systemctl disable --now ssh 2>/dev/null || true
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y openssh-server postfix 2>/dev/null || true
  apt-get -y autoremove
'

# ── Set timezone ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"

# ── Install Samba ─────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y samba samba-common-bin acl attr
'

# ── Create group and share directory ──────────────────────────────────────────
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
  
  # Set default ACLs (new files/dirs inherit group rwx)
  if ! setfacl -d -m 'g:${SMB_GROUP}:rwx' -m 'm:rwx' '${SMB_SHARE_PATH}' 2>/dev/null; then
    echo '  WARNING: default ACLs not applied — filesystem lacks POSIX ACL support' >&2
  fi
"

# ── Write smb.conf ────────────────────────────────────────────────────────────
# hosts allow semantics: when set, only listed hosts may connect (no hosts deny needed)
if [[ -n "$SMB_HOSTS_ALLOW" ]]; then
  SMB_HOSTS_ALLOW_LINE="   hosts allow = ${SMB_HOSTS_ALLOW} 127.0.0.1"
else
  SMB_HOSTS_ALLOW_LINE="   # hosts allow = <unrestricted — set SMB_HOSTS_ALLOW in the creator script>"
fi

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  
  # Backup original
  [[ -f /etc/samba/smb.conf ]] && cp /etc/samba/smb.conf /etc/samba/smb.conf.orig
  
  cat > /etc/samba/smb.conf <<'SAMBA_CONF'
#======================= Global Settings =======================

[global]
   workgroup = ${SMB_WORKGROUP}
   server string = Samba File Server
   netbios name = ${SMB_SERVER_NAME}
   disable netbios = yes
   smb ports = 445
${SMB_HOSTS_ALLOW_LINE}

   security = user
   passdb backend = tdbsam
   map to guest = never

   server min protocol = ${SMB_MIN_PROTOCOL}
   client min protocol = ${SMB_MIN_PROTOCOL}
   server signing = ${SMB_SERVER_SIGNING}
   client signing = ${SMB_SERVER_SIGNING}
   smb encrypt = ${SMB_ENCRYPTION}
   # AES-256 preferred; AES-128-GCM kept so Windows 10, older macOS and
   # Android clients (AES-128 only) can still connect
   server smb3 encryption algorithms = AES-256-GCM, AES-256-CCM, AES-128-GCM
   server smb3 signing algorithms = AES-256-GMAC, AES-128-GMAC
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

[${SMB_SHARE_NAME}]
   comment = Shared Directory
   path = ${SMB_SHARE_PATH}
   browseable = yes
   writable = yes
   guest ok = no
   valid users = @${SMB_GROUP}
   create mask = 0664
   directory mask = 2775
   force group = ${SMB_GROUP}

   oplocks = yes
   level2 oplocks = yes

   # acl_xattr intentionally omitted: it stores NT ACLs in security.* xattrs,
   # which an unprivileged CT cannot write. POSIX perms + force group suffice here.
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

# ── Validate config ───────────────────────────────────────────────────────────
# Note: "Weak crypto is allowed by GnuTLS" is a cosmetic testparm message
# reflecting system GnuTLS state, not a config problem. Safe to ignore —
# smb.conf enforces SMB3 + mandatory encryption + ntlmv2-only.
if pct exec "$CT_ID" -- testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
  echo "  Configuration validation passed"
else
  echo "  ERROR: smb.conf validation failed" >&2
  pct exec "$CT_ID" -- testparm -s /etc/samba/smb.conf >&2 || true
  false
fi

# ── Start services ────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /var/log/samba
  systemctl disable --now nmbd 2>/dev/null || true
  systemctl mask nmbd 2>/dev/null || true
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

if pct exec "$CT_ID" -- sh -lc "ss -ltn 2>/dev/null | grep -q ':445 '" 2>/dev/null; then
  echo "  SMB port 445 is listening"
else
  echo "  WARNING: SMB port 445 is not listening." >&2
  pct exec "$CT_ID" -- journalctl -u smbd --no-pager -n 20 >&2 || true
fi

# ── Create first Samba user ───────────────────────────────────────────────────
if [[ -n "$SMB_USER" ]]; then
  if pct exec "$CT_ID" -- getent passwd "$SMB_USER" >/dev/null 2>&1; then
    echo "  WARNING: system user $SMB_USER already exists — adding to $SMB_GROUP instead of creating." >&2
    pct exec "$CT_ID" -- usermod -aG "$SMB_GROUP" "$SMB_USER"
  else
    pct exec "$CT_ID" -- useradd -M -s /usr/sbin/nologin -G "$SMB_GROUP" "$SMB_USER"
  fi
  printf '%s\n%s\n' "$SMB_USER_PASS" "$SMB_USER_PASS" \
    | pct exec "$CT_ID" -- smbpasswd -a -s "$SMB_USER"
  pct exec "$CT_ID" -- smbpasswd -e "$SMB_USER"
  echo "  Samba user created: $SMB_USER"
fi

# ── Unattended upgrades ───────────────────────────────────────────────────────
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

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ${EXTRA_PACKAGES[*]}
  "
fi

# ── Sysctl hardening ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  {
    cat <<'EOF'
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
    if [[ '${DISABLE_IPV6}' -eq 1 ]]; then
      cat <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    fi
  } > /etc/sysctl.d/99-hardening.conf
  sysctl --system >/dev/null 2>&1 || true
"

# ── Cleanup packages ──────────────────────────────────────────────────────────
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
printf '\n  Samba File Server (SMB3 encrypted)\n'
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
if systemctl is-active --quiet smbd 2>/dev/null; then
  printf '  Samba:     running\n'
else
  printf '  Samba:     stopped\n'
fi
printf '  Config:    /etc/samba/smb.conf\n'
printf '  Share:     ${SMB_SHARE_PATH}\n'
printf '  Storage:   ${SHARE_DERIVED}\n'
printf '  Group:     ${SMB_GROUP}\n'
printf '  Validate:  testparm -s\n'
printf '  Restart:   systemctl restart smbd\n'
printf '\n'
printf '  Add user:\n'
printf '    useradd -M -s /usr/sbin/nologin -G ${SMB_GROUP} <user>\n'
printf '    smbpasswd -a <user>\n'
printf '    smbpasswd -e <user>\n'
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

# ── Proxmox UI description ────────────────────────────────────────────────────
SMB_DESC="Samba File Server (${CT_IP})
<details><summary>Details</summary>Samba File Server (SMB3 encrypted) on Debian ${DEBIAN_VERSION} LXC
Share: ${SMB_SHARE_NAME} → ${SMB_SHARE_PATH}
Workgroup: ${SMB_WORKGROUP}
Created by samba.sh</details>"
pct set "$CT_ID" --description "$SMB_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "CT: $CT_ID | IP: ${CT_IP} | SMB: \\\\${CT_IP}\\${SMB_SHARE_NAME} | User: ${SMB_USER:-none} | Login: password set"
echo ""
echo "  Share storage:"
if [[ "$SHARE_STORAGE" == "rootfs" ]]; then
  echo "    ${SMB_SHARE_PATH} (rootfs — consider external storage for production)"
elif [[ "$SHARE_STORAGE" == /* ]]; then
  echo "    ${SHARE_STORAGE} -> ${SMB_SHARE_PATH} (CT mp0)"
else
  echo "    ${SHARE_DATASET} -> ${SHARE_HOST_PATH} -> ${SMB_SHARE_PATH} (CT mp0)"
fi
echo ""
echo "  Notes:"
if [[ "$SHARE_STORAGE" != "rootfs" ]]; then
  echo "    - The bind-mounted share is NOT included in vzdump backups of CT ${CT_ID}."
  echo "      Back up ${SHARE_HOST_PATH} on the host (e.g. ZFS snapshots / sanoid)."
fi
echo "    - NetBIOS is disabled: the server does not appear in Windows Network browsing."
echo "      Connect directly via \\\\${CT_IP}\\${SMB_SHARE_NAME} (or the DNS name)."
echo "    - DHCP lease: reserve ${CT_IP} for this CT in your DHCP server."
echo ""
echo "  Add more Samba users:"
echo "    pct exec $CT_ID -- useradd -M -s /usr/sbin/nologin -G $SMB_GROUP <username>"
echo "    pct exec $CT_ID -- smbpasswd -a <username>"
echo "    pct exec $CT_ID -- smbpasswd -e <username>"
echo ""
