#!/usr/bin/env bash
set -Eeuo pipefail

# vault-ca.sh — Proxmox VE creator for a hardened SSH CA vault LXC.
# Creates a fresh Debian LXC, installs + hardens sshd for a single admin
# user, sets up a dedicated `sshca` system user owning the CA private key,
# and drops in the `vault-ca` signing helper + a `ca-sign` workstation
# wrapper. This is a CREATOR, not an idempotent reconciler: running it
# against a host where the chosen CT_ID already exists is rejected in
# preflight, not patched in place. Re-running against an existing vault-ca
# CT is not supported — tear down and re-create.

# ── Config ────────────────────────────────────────────────────────────────────
# LXC sizing & placement
CT_ID=""                             # empty = auto-assign via pvesh; set e.g. CT_ID=121 to pin
HN="vault-ca"
CPU=1
RAM=1024
DISK=4
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Debian / tagging
APP_TZ="Europe/Berlin"
TAGS="debian;lxc;vault-ca;ssh-ca"
DEBIAN_VERSION=13

# Extra packages (on top of the base + vault packages added below)
EXTRA_PACKAGES=(
  curl
  jq
)

# Vault-CA admin user
ADMIN_USER="admin"
ADMIN_COMMENT="Vault-CA User"
ADMIN_SHELL="/bin/bash"
ADMIN_GROUPS=()                      # intentionally empty: admin must NOT be in sudo.
                                     # The only privilege escalation path is the
                                     # scoped drop-in at /etc/sudoers.d/vault-ca,
                                     # which allows exactly two binaries as sshca.
                                     # Putting admin in 'sudo' would let them read
                                     # /var/lib/ssh-ca/ca_user_key directly and
                                     # defeat the CA owner split.

# Optional: pre-seed admin's inbound SSH authorized_keys at deploy time.
# When set, you can SSH in immediately instead of `pct console`-ing to paste
# a key. Accepts either form:
#   ADMIN_SSH_PUBKEY="ssh-ed25519 AAAAC3Nz... you@workstation"
#   ADMIN_SSH_PUBKEY="/root/workstation_ed25519.pub"   # absolute path (or ~/…)
# Leave empty to keep the default behavior: sshd is still hardened to
# pubkey-only + AllowUsers ${ADMIN_USER}, and you add a key later via
# `pct console <CT_ID>` (step 1 of the bootstrap summary).
# Only the first non-empty, non-comment line is used. Private keys are rejected.
ADMIN_SSH_PUBKEY=""

# SSH service on the vault-ca CT itself
SSH_PORT=22
SSH_LISTEN_ADDRESS=""                # blank = all addresses
ALLOW_TCP_FORWARDING=0
ALLOW_AGENT_FORWARDING=0
ALLOW_X11_FORWARDING=0

# CA defaults written into /etc/vault-ca/config (runtime-overridable)
CA_DEFAULT_VALIDITY="+8h"
CA_MAX_VALIDITY_SEC=86400            # 24h hard ceiling, enforced in sign-user-cert
CA_DEFAULT_PRINCIPALS="root,admin"   # covers both common login names on targets;
                                     # override with -n on the client wrapper

# Helper paths (inside the CT)
VAULT_CA_BIN="/usr/local/bin/vault-ca"
VAULT_CA_SIGNER="/usr/local/lib/vault-ca/sign-user-cert"
VAULT_CA_KRL_HELPER="/usr/local/lib/vault-ca/update-krl"
VAULT_CA_WRAPPER="/usr/local/share/vault-ca/ca-sign"
VAULT_CA_CONFIG="/etc/vault-ca/config"
VAULT_CA_SUDOERS="/etc/sudoers.d/vault-ca"
SSHD_DROPIN_PATH="/etc/ssh/sshd_config.d/10-vault-ca-hardening.conf"

# CA material location (inside the CT)
CA_DIR="/var/lib/ssh-ca"
CA_KEY="${CA_DIR}/ca_user_key"
CA_PUB="${CA_DIR}/ca_user_key.pub"
AUDIT_LOG="/var/log/vault-ca.log"

# Behavior flags
DISABLE_IPV6=0                       # 1 = also disable IPv6 via sysctl hardening
LOCK_ROOT_PASSWORD=1                 # 1 = lock local root password after setup; pct enter still works
CLEANUP_ON_FAIL=1                    # 1 = destroy CT on error, 0 = keep for debugging

# ── Custom configs created by this script ─────────────────────────────────────
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-vault-ca
#   /etc/update-motd.d/99-footer
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf
#   /etc/ssh/sshd_config.d/10-vault-ca-hardening.conf
#   /etc/vault-ca/config
#   /etc/sudoers.d/vault-ca
#   /usr/local/bin/vault-ca
#   /usr/local/lib/vault-ca/sign-user-cert
#   /usr/local/lib/vault-ca/update-krl
#   /usr/local/share/vault-ca/ca-sign
#   /var/lib/ssh-ca/ca_user_key{,.pub}
#   /var/log/vault-ca.log

# ── Trap cleanup ──────────────────────────────────────────────────────────────
# SEED_SRC is a transient host-side tempfile used to stage ADMIN_SSH_PUBKEY
# for `pct push`. Declared up front so both traps can clean it up even if
# the push fails before we reach its own rm.
SEED_SRC=""

trap 'rc=$?;
  trap - ERR
  echo "  ERROR: failed (rc=$rc) near line ${BASH_LINENO[0]:-?}" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && "${CREATED:-0}" -eq 1 ]]; then
    echo "  Cleanup: stopping/destroying CT ${CT_ID} ..." >&2
    pct stop "${CT_ID}" >/dev/null 2>&1 || true
    pct destroy "${CT_ID}" >/dev/null 2>&1 || true
  fi
  [[ -n "${SEED_SRC:-}"    && -e "${SEED_SRC}"    ]] && rm -f "${SEED_SRC}"    || true
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
  [[ -n "${SEED_SRC:-}"    && -e "${SEED_SRC}"    ]] && rm -f "${SEED_SRC}"    || true
  [[ -n "${HOST_TMPDIR:-}" && -d "${HOST_TMPDIR}" ]] && rm -rf "${HOST_TMPDIR}" || true
  exit "$rc"
' INT TERM

# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct qm pvesm curl python3 ip awk grep sed sort paste seq mktemp ssh-keygen; do
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

if (( ${#HN} > 253 )) \
   || ! [[ "$HN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
  echo "  ERROR: Invalid hostname: $HN" >&2
  exit 1
fi

[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
  || { echo "  ERROR: ADMIN_USER must match ^[a-z_][a-z0-9_-]{0,31}$" >&2; exit 1; }
[[ "$ADMIN_USER" != "root" ]] || { echo "  ERROR: ADMIN_USER must not be root." >&2; exit 1; }
[[ "$ADMIN_USER" != "sshca" ]] || { echo "  ERROR: ADMIN_USER must not be 'sshca' (reserved for CA owner)." >&2; exit 1; }

# ADMIN_SHELL and ADMIN_COMMENT are interpolated into 'bash -lc "..."'
# blocks below — often inside single-quoted strings passed through another
# shell. A stray quote, newline, or backslash would break the generated
# command. Not a remote-exploit concern in normal use, but the config
# section is explicitly operator-editable, so validate defensively.
[[ "$ADMIN_SHELL" =~ ^/[A-Za-z0-9._/+:-]+$ ]] \
  || { echo "  ERROR: ADMIN_SHELL must be an absolute path matching ^/[A-Za-z0-9._/+:-]+$: $ADMIN_SHELL" >&2; exit 1; }
if [[ "$ADMIN_COMMENT" == *\'*  \
   || "$ADMIN_COMMENT" == *\"*  \
   || "$ADMIN_COMMENT" == *\\*  \
   || "$ADMIN_COMMENT" == *$'\n'* \
   || "$ADMIN_COMMENT" == *$'\r'* ]]; then
  echo "  ERROR: ADMIN_COMMENT must not contain quotes, backslashes, or newlines." >&2
  exit 1
fi

# ADMIN_SSH_PUBKEY: resolve (file-or-literal), sanity-check, and validate.
# Produces ADMIN_PUBKEY_LINE, consumed later by the seeding step. Empty
# when ADMIN_SSH_PUBKEY is empty — that keeps the console-paste flow.
ADMIN_PUBKEY_LINE=""
if [[ -n "$ADMIN_SSH_PUBKEY" ]]; then
  if [[ "$ADMIN_SSH_PUBKEY" == /* || "$ADMIN_SSH_PUBKEY" == "~/"* ]]; then
    # Path form. Expand a leading ~/ against $HOME, falling back to /root
    # for environments where HOME is unset (rare, but this runs as root).
    _home="${HOME:-/root}"
    _keysrc="${ADMIN_SSH_PUBKEY/#\~\//$_home/}"
    unset _home
    [[ -r "$_keysrc" ]] \
      || { echo "  ERROR: ADMIN_SSH_PUBKEY file not readable: $_keysrc" >&2; exit 1; }
    if grep -qE "BEGIN [A-Z ]*PRIVATE KEY" "$_keysrc"; then
      echo "  ERROR: ADMIN_SSH_PUBKEY points at a private key: $_keysrc" >&2
      echo "         Use the matching .pub file instead." >&2
      exit 1
    fi
    ADMIN_PUBKEY_LINE="$(awk 'NF && !/^[[:space:]]*#/ {print; exit}' "$_keysrc")"
    unset _keysrc
  else
    # Literal form. Take the first non-empty, non-comment line.
    if printf '%s' "$ADMIN_SSH_PUBKEY" | grep -qE "BEGIN [A-Z ]*PRIVATE KEY"; then
      echo "  ERROR: ADMIN_SSH_PUBKEY looks like a private key. Use the .pub instead." >&2
      exit 1
    fi
    ADMIN_PUBKEY_LINE="$(printf '%s\n' "$ADMIN_SSH_PUBKEY" \
                         | awk 'NF && !/^[[:space:]]*#/ {print; exit}')"
  fi

  [[ -n "$ADMIN_PUBKEY_LINE" ]] \
    || { echo "  ERROR: ADMIN_SSH_PUBKEY produced no usable key line." >&2; exit 1; }

  # Authoritative check: ssh-keygen -l rejects anything that isn't a valid
  # authorized_keys/.pub single-line entry.
  _keytmp="$(mktemp)"
  printf '%s\n' "$ADMIN_PUBKEY_LINE" > "$_keytmp"
  if ! ssh-keygen -l -f "$_keytmp" >/dev/null 2>&1; then
    rm -f "$_keytmp"
    echo "  ERROR: ADMIN_SSH_PUBKEY is not a valid OpenSSH public key." >&2
    exit 1
  fi
  rm -f "$_keytmp"
fi

[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) \
  || { echo "  ERROR: SSH_PORT must be between 1 and 65535." >&2; exit 1; }

# Default-port examples stay clean (no bare '-p 22' noise); custom ports get
# an explicit '-p N' wherever the script prints an ssh command for the user.
# Two forms are used:
#   SSH_PORT_ARG — leading-space flag fragment, concatenated after 'ssh' in
#                  host-side printed strings ("ssh${SSH_PORT_ARG} admin@...").
#   SSH_CMD_STR  — full command prefix ('ssh' or 'ssh -p N'), substituted
#                  into embedded templates via the __SSH_CMD__ placeholder.
if (( SSH_PORT == 22 )); then
  SSH_PORT_ARG=""
  SSH_CMD_STR="ssh"
else
  SSH_PORT_ARG=" -p $SSH_PORT"
  SSH_CMD_STR="ssh -p $SSH_PORT"
fi

[[ "$ALLOW_TCP_FORWARDING" =~ ^[01]$ ]]   || { echo "  ERROR: ALLOW_TCP_FORWARDING must be 0 or 1." >&2; exit 1; }
[[ "$ALLOW_AGENT_FORWARDING" =~ ^[01]$ ]] || { echo "  ERROR: ALLOW_AGENT_FORWARDING must be 0 or 1." >&2; exit 1; }
[[ "$ALLOW_X11_FORWARDING" =~ ^[01]$ ]]   || { echo "  ERROR: ALLOW_X11_FORWARDING must be 0 or 1." >&2; exit 1; }

if [[ -n "$SSH_LISTEN_ADDRESS" ]] && ! [[ "$SSH_LISTEN_ADDRESS" =~ ^[A-Za-z0-9:._-]+$ ]]; then
  echo "  ERROR: SSH_LISTEN_ADDRESS contains invalid characters." >&2
  exit 1
fi

[[ "$CA_DEFAULT_VALIDITY" =~ ^\+[0-9]+[sSmMhHdDwW]$ ]] \
  || { echo "  ERROR: CA_DEFAULT_VALIDITY must match ^\\+[0-9]+[sSmMhHdDwW]$ (e.g. +8h)." >&2; exit 1; }
[[ "$CA_MAX_VALIDITY_SEC" =~ ^[0-9]+$ ]] && (( CA_MAX_VALIDITY_SEC > 0 )) \
  || { echo "  ERROR: CA_MAX_VALIDITY_SEC must be a positive integer (seconds)." >&2; exit 1; }

[[ "$CA_DEFAULT_PRINCIPALS" =~ ^[a-z_][a-z0-9_-]{0,31}(,[a-z_][a-z0-9_-]{0,31})*$ ]] \
  || { echo "  ERROR: CA_DEFAULT_PRINCIPALS must be a comma-separated list of valid usernames." >&2; exit 1; }

# ── Discover available resources ──────────────────────────────────────────────
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^vmbr' | sort | paste -sd, | sed 's/,/, /g' || echo "n/a")"
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"

# ── Show defaults & confirm ───────────────────────────────────────────────────
# Reflect ADMIN_SSH_PUBKEY state in both the summary table and the
# "after this script runs" bullet list so the confirmation screen matches
# what will actually happen.
if [[ -n "$ADMIN_PUBKEY_LINE" ]]; then
  ADMIN_KEY_SUMMARY="pre-seeded (1 key)"
  ADMIN_KEY_NOTE_LEAD="Inbound SSH will accept the pre-seeded admin key at:"
else
  ADMIN_KEY_SUMMARY="<not set> (add one via 'pct console' after deploy)"
  ADMIN_KEY_NOTE_LEAD="Inbound SSH stays locked until you add a key to:"
fi

cat <<EOF2

  Vault-CA LXC Creator — Configuration
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
  Admin SSH key:       $ADMIN_KEY_SUMMARY
  SSH port:            $SSH_PORT
  SSH listen address:  ${SSH_LISTEN_ADDRESS:-<all>}
  TCP forwarding:      $([ "$ALLOW_TCP_FORWARDING" -eq 1 ] && echo 'yes' || echo 'no')
  Agent forwarding:    $([ "$ALLOW_AGENT_FORWARDING" -eq 1 ] && echo 'yes' || echo 'no')
  X11 forwarding:      $([ "$ALLOW_X11_FORWARDING" -eq 1 ] && echo 'yes' || echo 'no')
  Lock root password:  $([ "$LOCK_ROOT_PASSWORD" -eq 1 ] && echo 'yes (no prompt; root left locked)' || echo 'no (will prompt)')
  IPv6:                $([ "$DISABLE_IPV6" -eq 1 ] && echo 'disabled (net + sysctl)' || echo 'auto (SLAAC)')
  Cleanup on fail:     $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  CA default validity: $CA_DEFAULT_VALIDITY
  CA max validity:     $CA_MAX_VALIDITY_SEC s ($(( CA_MAX_VALIDITY_SEC / 3600 )) h)
  CA default principals: $CA_DEFAULT_PRINCIPALS
  ────────────────────────────────────────
  After this script runs:
    • CA keypair is generated during provisioning (sshca user owns it).
    • Admin can sign certs via 'vault-ca sign ...'.
    • $ADMIN_KEY_NOTE_LEAD
        /home/$ADMIN_USER/.ssh/authorized_keys
    • pct enter remains available as a fallback.

  To change defaults, press Enter and edit the Config section
  at the top of this script, then re-run.

EOF2

SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/vault-ca.sh"
SCRIPT_LOCAL="/root/vault-ca.sh"
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
  read -r -s -p "  Set local console/login password for ${ADMIN_USER}: " PW1; echo
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
NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
if [[ "$DISABLE_IPV6" -eq 1 ]]; then
  NET0+=",ip6=manual"
else
  NET0+=",ip6=auto"
fi

EXTRA_PACKAGES_Q="$(printf ' %q' "${EXTRA_PACKAGES[@]}")"
if (( ${#ADMIN_GROUPS[@]} > 0 )); then
  ADMIN_GROUPS_Q="$(printf ' %q' "${ADMIN_GROUPS[@]}")"
else
  ADMIN_GROUPS_Q=""
fi

PCT_OPTIONS=(
  -hostname "$HN"
  -cores "$CPU"
  -memory "$RAM"
  -rootfs "${CONTAINER_STORAGE}:${DISK}"
  -onboot 0
  -ostype debian
  -unprivileged 1
  -tty 2
  -console 1
  -tags "$TAGS"
  -net0 "$NET0"
)

pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}"
CREATED=1

pct set "$CT_ID" --cmode tty

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

# ── Optional: set root password via stdin ─────────────────────────────────────
if [[ "$LOCK_ROOT_PASSWORD" -eq 0 && -n "$ROOT_PASSWORD" ]]; then
  printf 'root:%s\n' "$ROOT_PASSWORD" | pct exec "$CT_ID" -- chpasswd
  unset ROOT_PASSWORD
fi

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

# ── Base + vault-ca packages ──────────────────────────────────────────────────
# openssh-server is deliberately KEPT — this is a login host. openssh-client
# is needed for the 'trust' and 'krl deploy' verbs. man-db + manpages stay
# on-box so ssh(1), ssh-keygen(1), sshd_config(5) are available when
# debugging at 2am without outbound network access.
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends \
    openssh-server openssh-client sudo ca-certificates man-db manpages
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

# ── Vault-CA: admin user creation ─────────────────────────────────────────────
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

  rm -f \"/etc/sudoers.d/90-${ADMIN_USER}-nopasswd\"
"

printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | pct exec "$CT_ID" -- chpasswd
unset ADMIN_PASSWORD

# Scaffold ~/.ssh (inbound login only; outbound is via certs, not stored keys)
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  ADMIN_GROUP=\"\$(id -gn '${ADMIN_USER}')\"
  [[ -n \"\$ADMIN_GROUP\" ]] || { echo '  ERROR: Could not resolve primary group for ${ADMIN_USER}' >&2; exit 1; }

  ADMIN_HOME=\"\$(getent passwd '${ADMIN_USER}' | awk -F: '{print \$6}')\"
  [[ -n \"\$ADMIN_HOME\" && -d \"\$ADMIN_HOME\" ]] || { echo '  ERROR: Could not resolve home for ${ADMIN_USER}' >&2; exit 1; }

  install -d -m 0700 -o '${ADMIN_USER}' -g \"\$ADMIN_GROUP\" \"\$ADMIN_HOME/.ssh\"
  [[ -e \"\$ADMIN_HOME/.ssh/authorized_keys\" ]] || touch \"\$ADMIN_HOME/.ssh/authorized_keys\"
  [[ -e \"\$ADMIN_HOME/.ssh/known_hosts\"     ]] || touch \"\$ADMIN_HOME/.ssh/known_hosts\"
  chown '${ADMIN_USER}':\"\$ADMIN_GROUP\" \"\$ADMIN_HOME/.ssh/authorized_keys\" \"\$ADMIN_HOME/.ssh/known_hosts\"
  chmod 0600 \"\$ADMIN_HOME/.ssh/authorized_keys\" \"\$ADMIN_HOME/.ssh/known_hosts\"
  chmod 0700 \"\$ADMIN_HOME/.ssh\"
"

# Seed ADMIN_SSH_PUBKEY if provided. pct push avoids shell-quoting the key.
# Idempotent: grep -qxF skips the append when the line is already present.
# SEED_SRC is declared near the trap handlers so a failure in pct push or
# pct exec still gets the host-side tempfile cleaned up.
if [[ -n "$ADMIN_PUBKEY_LINE" ]]; then
  SEED_SRC="$(mktemp)"
  printf '%s\n' "$ADMIN_PUBKEY_LINE" > "$SEED_SRC"
  pct push "$CT_ID" "$SEED_SRC" "/tmp/admin_seed.pub" --perms 0600
  rm -f "$SEED_SRC"
  SEED_SRC=""
  pct exec "$CT_ID" -- bash -lc "
    set -euo pipefail
    ADMIN_GROUP=\"\$(id -gn '${ADMIN_USER}')\"
    ADMIN_HOME=\"\$(getent passwd '${ADMIN_USER}' | awk -F: '{print \$6}')\"
    AK=\"\$ADMIN_HOME/.ssh/authorized_keys\"
    SEED_LINE=\"\$(cat /tmp/admin_seed.pub)\"
    if ! grep -qxF \"\$SEED_LINE\" \"\$AK\" 2>/dev/null; then
      printf '%s\n' \"\$SEED_LINE\" >> \"\$AK\"
      echo '  Seeded admin pubkey into authorized_keys'
    else
      echo '  Admin pubkey already present in authorized_keys (skip)'
    fi
    rm -f /tmp/admin_seed.pub
    chown '${ADMIN_USER}':\"\$ADMIN_GROUP\" \"\$AK\"
    chmod 0600 \"\$AK\"
  "
fi

# ── Vault-CA: sshca system user + CA directory ────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  if ! getent passwd sshca >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/ssh-ca --shell /usr/sbin/nologin \
            --comment "SSH CA owner" sshca
    echo "  Created system user: sshca"
  fi
  install -d -m 0750 -o sshca -g sshca /var/lib/ssh-ca
  install -d -m 0755 -o root  -g root  /usr/local/lib/vault-ca
  install -d -m 0755 -o root  -g root  /usr/local/share/vault-ca
  install -d -m 0755 -o root  -g root  /etc/vault-ca
  # Audit log: operational logging, not tamper-resistant forensic logging.
  # sshca owns it so the signer can append without sudo. This means the same
  # account that holds the CA private key can also rewrite its own trail;
  # accept that trade-off here and rely on PBS snapshots for off-box audit.
  : >> /var/log/vault-ca.log
  chown sshca:adm /var/log/vault-ca.log
  chmod 0640 /var/log/vault-ca.log
'

# ── Vault-CA: write runtime config ────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  cat > '${VAULT_CA_CONFIG}' <<EOF2
# /etc/vault-ca/config — runtime configuration for vault-ca helpers.
# Sourced by /usr/local/bin/vault-ca and /usr/local/lib/vault-ca/sign-user-cert.
# Values are validated at use time; editing is safe but restart not required.
VAULT_CA_DEFAULT_VALIDITY=\"${CA_DEFAULT_VALIDITY}\"
VAULT_CA_MAX_VALIDITY_SEC=${CA_MAX_VALIDITY_SEC}
VAULT_CA_DEFAULT_PRINCIPALS=\"${CA_DEFAULT_PRINCIPALS}\"
EOF2
  chmod 0644 '${VAULT_CA_CONFIG}'
"

# ── Vault-CA: build signing helper on host, push into CT ──────────────────────
HOST_TMPDIR="$(mktemp -d)"
SIGNER_SRC="${HOST_TMPDIR}/sign-user-cert"

cat > "$SIGNER_SRC" <<'SIGNER_EOF'
#!/usr/bin/env bash
# /usr/local/lib/vault-ca/sign-user-cert
# Privileged signing helper. Invoked only via `sudo -u sshca` from vault-ca.
# All arguments are strictly named and validated — the sudoers NOPASSWD
# grant is scoped to this binary and the KRL helper only, so the admin
# shell cannot pass arbitrary ssh-keygen flags or read the CA private key.
set -Eeuo pipefail
umask 077

readonly CONFIG="/etc/vault-ca/config"
readonly CA_DIR="/var/lib/ssh-ca"
readonly CA_KEY="${CA_DIR}/ca_user_key"
readonly SERIAL_FILE="${CA_DIR}/next_serial"
readonly SERIAL_LOCK="${CA_DIR}/.serial.lock"
readonly AUDIT_LOG="/var/log/vault-ca.log"

[[ "$(id -un)" == "sshca" ]] \
  || { echo "  ERROR: sign-user-cert must run as sshca" >&2; exit 1; }
# shellcheck disable=SC1090
[[ -r "$CONFIG" ]] && . "$CONFIG"
[[ -f "$CA_KEY" ]] \
  || { echo "  ERROR: CA key not initialised at $CA_KEY" >&2; exit 1; }

MAX_VALIDITY_SEC="${VAULT_CA_MAX_VALIDITY_SEC:-86400}"

IDENTITY=""
PRINCIPALS=""
VALIDITY=""
PUBKEY_PATH=""
OPERATOR=""

while (( $# > 0 )); do
  case "$1" in
    --identity)   IDENTITY="$2";    shift 2 ;;
    --principals) PRINCIPALS="$2";  shift 2 ;;
    --validity)   VALIDITY="$2";    shift 2 ;;
    --pubkey)     PUBKEY_PATH="$2"; shift 2 ;;
    --operator)   OPERATOR="$2";    shift 2 ;;
    *) echo "  ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ "$IDENTITY" =~ ^[A-Za-z0-9._@:/+-]{1,128}$ ]] \
  || { echo "  ERROR: invalid identity (allowed [A-Za-z0-9._@:/+-], 1-128 chars)" >&2; exit 1; }
[[ "$PRINCIPALS" =~ ^[a-z_][a-z0-9_-]{0,31}(,[a-z_][a-z0-9_-]{0,31})*$ ]] \
  || { echo "  ERROR: invalid principals list" >&2; exit 1; }
[[ "$VALIDITY" =~ ^\+[0-9]+[sSmMhHdDwW]$ ]] \
  || { echo "  ERROR: invalid validity (e.g. +8h, +30m, +7d)" >&2; exit 1; }
[[ -f "$PUBKEY_PATH" && -r "$PUBKEY_PATH" ]] \
  || { echo "  ERROR: pubkey not readable: $PUBKEY_PATH" >&2; exit 1; }
[[ "$OPERATOR" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
  || { echo "  ERROR: invalid operator" >&2; exit 1; }

# Enforce max validity by converting to seconds.
VAL_NUM="${VALIDITY:1:${#VALIDITY}-2}"
VAL_UNIT="${VALIDITY: -1}"
[[ "$VAL_NUM" =~ ^[0-9]+$ ]] || { echo "  ERROR: invalid validity number" >&2; exit 1; }
case "$VAL_UNIT" in
  s|S) VAL_SEC=$(( VAL_NUM )) ;;
  m|M) VAL_SEC=$(( VAL_NUM * 60 )) ;;
  h|H) VAL_SEC=$(( VAL_NUM * 3600 )) ;;
  d|D) VAL_SEC=$(( VAL_NUM * 86400 )) ;;
  w|W) VAL_SEC=$(( VAL_NUM * 604800 )) ;;
  *) echo "  ERROR: invalid validity unit (allowed: s m h d w, case-insensitive)" >&2; exit 1 ;;
esac
(( VAL_SEC <= MAX_VALIDITY_SEC )) \
  || { echo "  ERROR: requested validity (${VAL_SEC}s) exceeds max (${MAX_VALIDITY_SEC}s)" >&2; exit 1; }

# Validate pubkey is parseable.
ssh-keygen -l -f "$PUBKEY_PATH" >/dev/null 2>&1 \
  || { echo "  ERROR: $PUBKEY_PATH is not a valid SSH public key" >&2; exit 1; }
FPR="$(ssh-keygen -l -E sha256 -f "$PUBKEY_PATH" | awk '{print $2}')"

# Reject already-signed certificates — we sign raw pubkeys only. The
# (sk-)? prefix accepts FIDO/U2F-backed cert algorithms like
# sk-ssh-ed25519-cert-v01@openssh.com and sk-ecdsa-sha2-nistp256-cert-v01@openssh.com.
if grep -qE '^(sk-)?(ssh|ecdsa)-[a-z0-9-]+-cert-v[0-9]+@openssh\.com ' "$PUBKEY_PATH"; then
  echo "  ERROR: input is already a certificate; sign raw pubkeys only" >&2
  exit 1
fi

# Allocate a serial atomically.
touch "$SERIAL_LOCK"
chmod 0600 "$SERIAL_LOCK"
SERIAL=""
{
  flock -x 9
  if [[ -s "$SERIAL_FILE" ]]; then
    SERIAL="$(< "$SERIAL_FILE")"
  else
    SERIAL=1
  fi
  [[ "$SERIAL" =~ ^[0-9]+$ ]] || SERIAL=1
  printf '%s\n' "$(( SERIAL + 1 ))" > "${SERIAL_FILE}.new"
  mv "${SERIAL_FILE}.new" "$SERIAL_FILE"
} 9>"$SERIAL_LOCK"
[[ -n "$SERIAL" ]] || { echo "  ERROR: serial allocation failed" >&2; exit 1; }

# Sign in a scratch dir.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$PUBKEY_PATH" "$WORK/k.pub"
ssh-keygen -q -s "$CA_KEY" \
  -I "$IDENTITY" \
  -n "$PRINCIPALS" \
  -V "$VALIDITY" \
  -z "$SERIAL" \
  "$WORK/k.pub"

# Emit certificate to stdout.
cat "$WORK/k-cert.pub"

# Audit log (JSON lines).
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"sign","operator":"%s","identity":"%s","principals":"%s","validity":"%s","serial":"%s","fingerprint":"%s"}\n' \
  "$TS" "$OPERATOR" "$IDENTITY" "$PRINCIPALS" "$VALIDITY" "$SERIAL" "$FPR" \
  >> "$AUDIT_LOG"
SIGNER_EOF

pct push "$CT_ID" "$SIGNER_SRC" "$VAULT_CA_SIGNER" --perms 0755
pct exec "$CT_ID" -- chown root:root "$VAULT_CA_SIGNER"

# ── Vault-CA: build KRL helper on host, push into CT ──────────────────────────
KRL_SRC="${HOST_TMPDIR}/update-krl"

cat > "$KRL_SRC" <<'KRL_EOF'
#!/usr/bin/env bash
# /usr/local/lib/vault-ca/update-krl
# Privileged KRL editor. Invoked only via `sudo -u sshca` from vault-ca.
set -Eeuo pipefail
umask 077

readonly CA_DIR="/var/lib/ssh-ca"
readonly CA_PUB="${CA_DIR}/ca_user_key.pub"
readonly KRL="${CA_DIR}/krl"
readonly KRL_SPEC="${CA_DIR}/krl.spec"
readonly KRL_LOCK="${CA_DIR}/.krl.lock"
readonly AUDIT_LOG="/var/log/vault-ca.log"

[[ "$(id -un)" == "sshca" ]] \
  || { echo "  ERROR: update-krl must run as sshca" >&2; exit 1; }

# Build or rebuild the binary KRL from the spec file. ssh-keygen -k needs
# -s <ca_pub> so that serial: / id: entries in the spec are scoped to the
# correct CA. Omitting -s makes serial/id revocations silently ineffective.
rebuild_krl() {
  [[ -f "$CA_PUB" ]] || { echo "  ERROR: CA public key missing at $CA_PUB" >&2; exit 1; }
  if [[ -s "$KRL_SPEC" ]]; then
    ssh-keygen -k -s "$CA_PUB" -f "$KRL" "$KRL_SPEC"
  else
    rm -f "$KRL"
  fi
}

op="${1:-}"
case "$op" in
  add-serial)
    serial="${2:-}"; operator="${3:-}"
    [[ "$serial"   =~ ^[0-9]+$ ]]                    || { echo "  ERROR: invalid serial" >&2; exit 1; }
    [[ "$operator" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]    || { echo "  ERROR: invalid operator" >&2; exit 1; }
    touch "$KRL_LOCK"; chmod 0600 "$KRL_LOCK"
    {
      flock -x 8
      touch "$KRL_SPEC"
      if grep -qxF "serial: ${serial}" "$KRL_SPEC"; then
        echo "  serial ${serial} already revoked"
      else
        echo "serial: ${serial}" >> "$KRL_SPEC"
        rebuild_krl
        printf '{"ts":"%s","event":"revoke","operator":"%s","serial":"%s"}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$operator" "$serial" >> "$AUDIT_LOG"
        echo "  Revoked serial: ${serial}"
      fi
    } 8>"$KRL_LOCK"
    ;;
  unrevoke-serial)
    serial="${2:-}"; operator="${3:-}"
    [[ "$serial"   =~ ^[0-9]+$ ]]                    || { echo "  ERROR: invalid serial" >&2; exit 1; }
    [[ "$operator" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]    || { echo "  ERROR: invalid operator" >&2; exit 1; }
    touch "$KRL_LOCK"; chmod 0600 "$KRL_LOCK"
    {
      flock -x 8
      if [[ -f "$KRL_SPEC" ]] && grep -qxF "serial: ${serial}" "$KRL_SPEC"; then
        { grep -vxF "serial: ${serial}" "$KRL_SPEC" || true; } > "${KRL_SPEC}.new"
        mv "${KRL_SPEC}.new" "$KRL_SPEC"
        rebuild_krl
        printf '{"ts":"%s","event":"unrevoke","operator":"%s","serial":"%s"}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$operator" "$serial" >> "$AUDIT_LOG"
        echo "  Unrevoked serial: ${serial}"
      else
        echo "  serial ${serial} was not in the KRL"
      fi
    } 8>"$KRL_LOCK"
    ;;
  show)
    # The spec file is the human-readable source of truth. Also print the
    # parsed binary view via ssh-keygen -Q -l -f if it's available.
    if [[ -s "$KRL_SPEC" ]]; then
      echo "  KRL spec (${KRL_SPEC}):"
      sed 's/^/    /' "$KRL_SPEC"
      if [[ -f "$KRL" ]]; then
        echo ""
        echo "  KRL binary summary:"
        ssh-keygen -Q -l -f "$KRL" 2>&1 | sed 's/^/    /' || true
      fi
    else
      echo "  (no revocations)"
    fi
    ;;
  cat-krl)
    # Emit the binary KRL (may be empty/absent if no revocations). On absence,
    # we still emit a valid empty file so 'krl deploy' can clear a target's KRL.
    if [[ -f "$KRL" ]]; then
      cat "$KRL"
    else
      # Empty output is a valid "no revocations" signal; ssh-keygen on the
      # receiving side is robust to an empty file when used as RevokedKeys.
      :
    fi
    ;;
  *)
    echo "usage: update-krl {add-serial SERIAL OPERATOR | unrevoke-serial SERIAL OPERATOR | show | cat-krl}" >&2
    exit 1
    ;;
esac
KRL_EOF

pct push "$CT_ID" "$KRL_SRC" "$VAULT_CA_KRL_HELPER" --perms 0755
pct exec "$CT_ID" -- chown root:root "$VAULT_CA_KRL_HELPER"

# ── Vault-CA: build main helper on host, push into CT ─────────────────────────
VAULT_CA_SRC="${HOST_TMPDIR}/vault-ca"

cat > "$VAULT_CA_SRC" <<'VAULTCA_EOF'
#!/usr/bin/env bash
# /usr/local/bin/vault-ca — SSH CA signing helper (unprivileged entry point)
set -Eeuo pipefail
umask 022

readonly CONFIG="/etc/vault-ca/config"
readonly CA_DIR="/var/lib/ssh-ca"
readonly CA_PUB="${CA_DIR}/ca_user_key.pub"
readonly AUDIT_LOG="/var/log/vault-ca.log"
readonly SIGN_BIN="/usr/local/lib/vault-ca/sign-user-cert"
readonly KRL_BIN="/usr/local/lib/vault-ca/update-krl"
readonly WRAPPER_SRC="/usr/local/share/vault-ca/ca-sign"

# Defaults (overridable via /etc/vault-ca/config)
VAULT_CA_DEFAULT_VALIDITY="+8h"
VAULT_CA_MAX_VALIDITY_SEC=86400
VAULT_CA_DEFAULT_PRINCIPALS="root,admin"
# shellcheck disable=SC1090
[[ -r "$CONFIG" ]] && . "$CONFIG"

die() { echo "  ERROR: $*" >&2; exit 1; }

# Who is actually running this, regardless of sudo chain.
operator_name() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    printf '%s' "$SUDO_USER"
  else
    id -un
  fi
}

usage() {
  cat <<USAGE
Usage:
  vault-ca help
  vault-ca init                                  # create CA if absent (idempotent)
  vault-ca sign <label> [opts] [pubkey|-]        # sign a pubkey, emit cert on stdout
  vault-ca list [-n N]                           # recent signings (newest last)
  vault-ca show-ca-pub                           # emit CA public key
  vault-ca fingerprint                           # CA key fingerprint

Target trust (recommended — from your workstation, no outbound SSH on vault):
  vault-ca trust-bundle                          # emit a trust installer script
  vault-ca untrust-bundle                        # emit an untrust installer script
  vault-ca krl-bundle                            # emit a KRL installer script

Target trust (convenience — requires outbound SSH creds on the vault):
  vault-ca trust <user@host> [--port N]          # pipe trust bundle to target
  vault-ca untrust <user@host> [--port N]        # pipe untrust bundle to target
  vault-ca krl deploy <user@host> [--port N]     # pipe KRL bundle to target

Client wrapper + revocation:
  vault-ca client-wrapper                        # emit ca-sign workstation script
  vault-ca revoke <serial>                       # add serial to KRL
  vault-ca unrevoke <serial>                     # remove serial from KRL
  vault-ca krl show                              # print current KRL
  vault-ca version                               # show helper version

Sign options:
  -V, --validity <spec>        e.g. +8h (default ${VAULT_CA_DEFAULT_VALIDITY}, max ${VAULT_CA_MAX_VALIDITY_SEC}s)
  -n, --principals <list>      comma-separated (default ${VAULT_CA_DEFAULT_PRINCIPALS})
  -I, --full-identity <str>    override composed -I (default: <operator>@<label>@<iso-ts>)

Examples (from your workstation):
  # One-time setup: install the client wrapper.
  __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca client-wrapper > ~/.local/bin/ca-sign && chmod +x ~/.local/bin/ca-sign

  # Sign a cert valid for +8h with default principals (root,admin).
  ca-sign

  # Trust the CA on a target (works even when vault has no outbound SSH):
  __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca trust-bundle | ssh root@web1.lab 'bash -s'

  # Overwrite an existing different CA trust on a target:
  __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca trust-bundle | ssh root@web1.lab 'FORCE=1 bash -s'

  # Revoke serial 42 and push the updated KRL out:
  __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca revoke 42
  __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca krl-bundle | ssh root@web1.lab 'bash -s'
USAGE
}

# ── init ──────────────────────────────────────────────────────────────────────
cmd_init() {
  if [[ -f "${CA_DIR}/ca_user_key" ]]; then
    echo "  CA already initialised: ${CA_DIR}/ca_user_key"
    ssh-keygen -l -f "${CA_DIR}/ca_user_key.pub" 2>/dev/null | sed 's/^/  /'
    return 0
  fi
  # Need root to run ssh-keygen as sshca. admin has no sudo on this host,
  # so the escalation path is from the PVE host (pct exec/pct enter).
  if [[ $EUID -ne 0 ]]; then
    die "init must be run as root — from the PVE host: 'pct exec <CTID> -- vault-ca init', or 'pct enter <CTID>' then run as root"
  fi
  install -d -m 0750 -o sshca -g sshca "$CA_DIR"
  sudo -n -u sshca ssh-keygen -q -t ed25519 \
        -f "${CA_DIR}/ca_user_key" -N "" \
        -C "vault-ca user CA ($(hostname -f 2>/dev/null || hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ))"
  chmod 0600 "${CA_DIR}/ca_user_key"
  chmod 0644 "${CA_DIR}/ca_user_key.pub"
  chown sshca:sshca "${CA_DIR}/ca_user_key" "${CA_DIR}/ca_user_key.pub"
  echo "  CA generated."
  ssh-keygen -l -f "${CA_DIR}/ca_user_key.pub" | sed 's/^/  /'
}

# ── sign ──────────────────────────────────────────────────────────────────────
cmd_sign() {
  local label="" pubkey_arg="" validity="$VAULT_CA_DEFAULT_VALIDITY"
  local principals="$VAULT_CA_DEFAULT_PRINCIPALS" full_identity=""

  label="${1:-}"
  [[ -n "$label" ]] || die "Usage: vault-ca sign <label> [opts] [pubkey|-]"
  shift

  while (( $# > 0 )); do
    case "$1" in
      -V|--validity)      validity="$2";      shift 2 ;;
      -n|--principals)    principals="$2";    shift 2 ;;
      -I|--full-identity) full_identity="$2"; shift 2 ;;
      -h|--help)          usage; return 0 ;;
      -)                  pubkey_arg="-";     shift ;;
      *)                  pubkey_arg="$1";    shift ;;
    esac
  done

  [[ "$label" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
    || die "label must match ^[A-Za-z0-9._-]{1,64}\$"
  [[ "$validity" =~ ^\+[0-9]+[sSmMhHdDwW]$ ]] \
    || die "validity must match ^\\+[0-9]+[sSmMhHdDwW]\$ (e.g. +8h, +30m, +7d)"
  [[ "$principals" =~ ^[a-z_][a-z0-9_-]{0,31}(,[a-z_][a-z0-9_-]{0,31})*$ ]] \
    || die "invalid principals list"
  if [[ -n "$full_identity" ]]; then
    [[ "$full_identity" =~ ^[A-Za-z0-9._@:/+-]{1,128}$ ]] \
      || die "full-identity must match ^[A-Za-z0-9._@:/+-]{1,128}\$"
  fi

  local tmp_pub
  tmp_pub="$(mktemp)"
  trap 'rm -f "$tmp_pub"' RETURN

  if [[ -z "$pubkey_arg" || "$pubkey_arg" == "-" ]]; then
    cat > "$tmp_pub"
  else
    [[ -f "$pubkey_arg" && -r "$pubkey_arg" ]] || die "cannot read pubkey: $pubkey_arg"
    cat "$pubkey_arg" > "$tmp_pub"
  fi
  # sshca must be able to read the tmp pubkey (public material, safe to widen).
  chmod 0644 "$tmp_pub"
  [[ -s "$tmp_pub" ]] || die "empty pubkey input"

  local operator ts identity
  operator="$(operator_name)"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  identity="${full_identity:-${operator}@${label}@${ts}}"

  sudo -n -u sshca "$SIGN_BIN" \
       --identity   "$identity" \
       --principals "$principals" \
       --validity   "$validity" \
       --pubkey     "$tmp_pub" \
       --operator   "$operator"
}

# ── list ──────────────────────────────────────────────────────────────────────
cmd_list() {
  local num=20
  while (( $# > 0 )); do
    case "$1" in
      -n|--num) num="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ "$num" =~ ^[0-9]+$ ]] && (( num > 0 )) || die "invalid -n value"
  [[ -r "$AUDIT_LOG" ]] || { echo "  (no signings recorded)"; return 0; }

  if command -v jq >/dev/null 2>&1; then
    {
      printf '  %-20s %-12s %-42s %-16s %-8s %-6s %s\n' \
        "TIME" "OPERATOR" "IDENTITY" "PRINCIPALS" "VALIDITY" "SERIAL" "FINGERPRINT"
      # Filter to sign events FIRST, then take the last N. tail-then-filter
      # would return fewer than N when revokes/unrevokes are interleaved.
      jq -r '
        select(.event == "sign") |
        [.ts, .operator, .identity, .principals, .validity, .serial, .fingerprint] | @tsv
      ' "$AUDIT_LOG" \
        | tail -n "$num" \
        | awk -F'\t' '{ printf "  %-20s %-12s %-42s %-16s %-8s %-6s %s\n", $1, $2, $3, $4, $5, $6, $7 }'
    }
  else
    # No jq: filter then tail, same intent. Use -F for a literal match on
    # the compact JSON key/value the signer emits — not a content match.
    # '|| true' neutralises grep's exit 1 when no sign events exist yet,
    # which would otherwise abort the pipeline under 'set -o pipefail'.
    { grep -F '"event":"sign"' "$AUDIT_LOG" || true; } | tail -n "$num"
  fi
}

# ── show-ca-pub ───────────────────────────────────────────────────────────────
cmd_show_ca_pub() {
  [[ -f "$CA_PUB" ]] || die "CA not initialised (no ${CA_PUB})"
  cat "$CA_PUB"
}

# ── fingerprint ───────────────────────────────────────────────────────────────
cmd_fingerprint() {
  [[ -f "$CA_PUB" ]] || die "CA not initialised (no ${CA_PUB})"
  ssh-keygen -l -E sha256 -f "$CA_PUB"
}

# ── trust / untrust ───────────────────────────────────────────────────────────
# Remote script reads CA pubkey from stdin (trust only); uses 'sudo -n' so it
# works both as root (no-op) and as a user with NOPASSWD sudo. sshd -t is
# run before the service is reloaded; on failure the drop-in is rolled back.
# ── trust / untrust / krl deploy ──────────────────────────────────────────────
# The vault builds a self-contained installer script with the CA pubkey (or
# KRL) base64-baked in. From the workstation:
#
#   __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca trust-bundle | ssh root@target 'bash -s'
#
# …which requires no outbound SSH on the vault. The 'trust'/'untrust'/'krl
# deploy' verbs are thin convenience wrappers that pipe the bundle to ssh
# from the vault itself; they only work if the admin has outbound creds.

_emit_trust_script() {
  [[ -f "$CA_PUB" ]] || die "CA not initialised (no ${CA_PUB})"
  local ca_pub_b64
  # Debian/coreutils assumption: base64 supports -w0 (no line-wrap).
  ca_pub_b64="$(base64 -w0 "$CA_PUB")"
  local stamp; stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat <<TRUST_HEADER
#!/usr/bin/env bash
# vault-ca trust installer — generated ${stamp}
# Run with: ssh root@target 'bash -s' < this-script
#           (or pipe from: __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca trust-bundle | ssh root@target 'bash -s')
# Env:  FORCE=1  overwrite an existing different CA pubkey on the target.
set -Eeuo pipefail
CA_PUB_B64='${ca_pub_b64}'
TRUST_HEADER

  cat <<'TRUST_BODY'
TRUST_PUB="/etc/ssh/ssh-ca-user.pub"
TRUST_CONF="/etc/ssh/sshd_config.d/20-ssh-ca.conf"
TRUST_KRL="/etc/ssh/ssh-ca-krl"
SSHD_MAIN="/etc/ssh/sshd_config"
SUFFIX=".vault-ca.pre-$(date +%s)"

# Sentinel wrapping any Include line we add. On untrust/rollback we only
# touch lines between these markers — we never rewrite pre-existing Include
# lines the operator or distro put there.
INCLUDE_BEGIN="# BEGIN vault-ca Include (added by trust-bundle)"
INCLUDE_END="# END vault-ca Include"

# Run a command with root privileges. If already root, exec directly (works
# on minimal images without sudo installed). Otherwise use sudo -n so the
# script fails fast if the invoking user lacks NOPASSWD.
RUN() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

NEW_PUB="$(printf '%s' "$CA_PUB_B64" | base64 -d)"

# Detect an existing CA pubkey. If it differs, refuse unless FORCE=1.
if RUN test -f "$TRUST_PUB"; then
  existing="$(RUN cat "$TRUST_PUB")"
  if [[ "$existing" != "$NEW_PUB" ]]; then
    if [[ "${FORCE:-0}" != "1" ]]; then
      echo "  ERROR: $TRUST_PUB already contains a different CA pubkey." >&2
      echo "         Re-run with FORCE=1 to overwrite (backups will be kept)." >&2
      exit 1
    fi
    echo "  WARNING: overwriting existing CA pubkey (FORCE=1)." >&2
  fi
fi

# Back up anything we might touch. sshd_config is backed up separately
# because we only modify it when the Include directive is missing.
BACKED_UP=()
for f in "$TRUST_PUB" "$TRUST_CONF" "$TRUST_KRL"; do
  if RUN test -f "$f"; then
    RUN cp -p "$f" "${f}${SUFFIX}"
    BACKED_UP+=("$f")
  fi
done

# Decide whether we need to touch sshd_config. A drop-in at
# /etc/ssh/sshd_config.d/20-ssh-ca.conf is ONLY honoured if sshd_config
# contains a matching 'Include /etc/ssh/sshd_config.d/*.conf' directive.
# Without it, the installer can pass 'sshd -t', reload ssh, and still
# leave CA auth inactive — so this check is mandatory, not cosmetic.
SSHD_MAIN_BACKED_UP=0
INCLUDE_ADDED=0
if RUN test -f "$SSHD_MAIN"; then
  # Match any Include line pointing at sshd_config.d with a *.conf glob
  # (the only form that will actually pick up our 20-ssh-ca.conf drop-in).
  # Absolute or relative path both count; commented (#-prefixed) lines
  # don't. A narrower Include (one specific file, no glob) is treated as
  # "no matching Include" — adding our own then results in two Include
  # directives, which sshd accepts fine.
  if ! RUN grep -Eq '^[[:space:]]*Include[[:space:]]+(/etc/ssh/)?sshd_config\.d/\*\.conf([[:space:]]|$)' "$SSHD_MAIN"; then
    RUN cp -p "$SSHD_MAIN" "${SSHD_MAIN}${SUFFIX}"
    SSHD_MAIN_BACKED_UP=1
    # Append the Include line wrapped in sentinels so untrust/rollback can
    # remove exactly what we added without touching anything else.
    RUN tee -a "$SSHD_MAIN" >/dev/null <<INCLUDE
${INCLUDE_BEGIN}
Include /etc/ssh/sshd_config.d/*.conf
${INCLUDE_END}
INCLUDE
    INCLUDE_ADDED=1
  fi
else
  echo "  ERROR: $SSHD_MAIN not found — is openssh-server installed?" >&2
  exit 1
fi

_rollback_fired=0
rollback() {
  (( _rollback_fired )) && return
  _rollback_fired=1
  trap - ERR
  echo "  Rolling back changes on $(hostname -s 2>/dev/null || hostname)..." >&2
  RUN rm -f "$TRUST_PUB" "$TRUST_CONF" "$TRUST_KRL" 2>/dev/null || true
  local f
  for f in "${BACKED_UP[@]}"; do
    if RUN test -f "${f}${SUFFIX}"; then
      RUN mv "${f}${SUFFIX}" "$f" 2>/dev/null || true
    fi
  done
  if (( SSHD_MAIN_BACKED_UP )) && RUN test -f "${SSHD_MAIN}${SUFFIX}"; then
    RUN mv "${SSHD_MAIN}${SUFFIX}" "$SSHD_MAIN" 2>/dev/null || true
  fi
}

# Any unhandled error after this point fires rollback and exits.
trap 'rollback; exit 1' ERR

# Install new files.
RUN install -d -m 0755 /etc/ssh/sshd_config.d

printf '%s\n' "$NEW_PUB" | RUN tee "$TRUST_PUB" >/dev/null
RUN chmod 0644 "$TRUST_PUB"

RUN tee "$TRUST_CONF" >/dev/null <<CONF
# Installed by vault-ca — do not edit by hand
TrustedUserCAKeys $TRUST_PUB
RevokedKeys $TRUST_KRL
CONF

# Pre-create an empty KRL. OpenSSH refuses pubkey auth entirely if RevokedKeys
# is referenced and unreadable, so this file must exist before sshd reloads.
if ! RUN test -f "$TRUST_KRL"; then
  RUN touch "$TRUST_KRL"
  RUN chmod 0644 "$TRUST_KRL"
fi

# sshd -t is expected to either pass or cleanly fail; use explicit if to
# preserve a useful error message before rollback runs.
if ! RUN sshd -t 2>&1; then
  echo "  ERROR: sshd -t failed after installing CA trust." >&2
  rollback
  exit 1
fi

# Debian target assumption: OpenSSH service name is 'ssh' here, not 'sshd'.
RUN systemctl reload ssh 2>/dev/null || RUN systemctl restart ssh

# Success: disarm trap and prune backups.
trap - ERR
for f in "${BACKED_UP[@]}"; do
  RUN rm -f "${f}${SUFFIX}" 2>/dev/null || true
done
if (( SSHD_MAIN_BACKED_UP )); then
  RUN rm -f "${SSHD_MAIN}${SUFFIX}" 2>/dev/null || true
fi

if (( INCLUDE_ADDED )); then
  echo "  Added 'Include /etc/ssh/sshd_config.d/*.conf' to $SSHD_MAIN"
fi
echo "  CA trust applied on $(hostname -s 2>/dev/null || hostname)"
TRUST_BODY
}

_emit_untrust_script() {
  [[ -f "$CA_PUB" ]] || die "CA not initialised (no ${CA_PUB})"
  local ca_pub_b64
  # Debian/coreutils assumption: base64 supports -w0 (no line-wrap).
  ca_pub_b64="$(base64 -w0 "$CA_PUB")"
  local stamp; stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat <<UNTRUST_HEADER
#!/usr/bin/env bash
# vault-ca untrust installer — generated ${stamp}
# Removes this specific CA's trust from the target (refuses to remove an
# unrelated CA). Env: FORCE=1 to remove even if the target's CA differs.
set -Eeuo pipefail
CA_PUB_B64='${ca_pub_b64}'
UNTRUST_HEADER

  cat <<'UNTRUST_BODY'
TRUST_PUB="/etc/ssh/ssh-ca-user.pub"
TRUST_CONF="/etc/ssh/sshd_config.d/20-ssh-ca.conf"
TRUST_KRL="/etc/ssh/ssh-ca-krl"
SSHD_MAIN="/etc/ssh/sshd_config"
SUFFIX=".vault-ca.pre-$(date +%s)"

INCLUDE_BEGIN="# BEGIN vault-ca Include (added by trust-bundle)"
INCLUDE_END="# END vault-ca Include"

RUN() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

THIS_PUB="$(printf '%s' "$CA_PUB_B64" | base64 -d)"

# Refuse to remove a CA we don't own unless forced.
if RUN test -f "$TRUST_PUB"; then
  existing="$(RUN cat "$TRUST_PUB")"
  if [[ "$existing" != "$THIS_PUB" && "${FORCE:-0}" != "1" ]]; then
    echo "  ERROR: target's $TRUST_PUB is a different CA. Refusing to remove." >&2
    echo "         Re-run with FORCE=1 to remove it anyway." >&2
    exit 1
  fi
fi

# Back up originals before removing them.
BACKED_UP=()
for f in "$TRUST_PUB" "$TRUST_CONF" "$TRUST_KRL"; do
  if RUN test -f "$f"; then
    RUN cp -p "$f" "${f}${SUFFIX}"
    BACKED_UP+=("$f")
  fi
done

# If trust-bundle added an Include block on this target, remove it. We
# match only the sentinel-wrapped block — any Include the operator or
# distro put there stands untouched.
SSHD_MAIN_BACKED_UP=0
INCLUDE_REMOVED=0
if RUN test -f "$SSHD_MAIN" \
   && RUN grep -qxF "$INCLUDE_BEGIN" "$SSHD_MAIN" 2>/dev/null; then
  RUN cp -p "$SSHD_MAIN" "${SSHD_MAIN}${SUFFIX}"
  SSHD_MAIN_BACKED_UP=1
  # sed /BEGIN/,/END/d removes the sentinels and everything between them.
  # Use a tempfile + mv instead of sed -i to preserve mode/owner precisely.
  tmp_sshd="$(RUN mktemp "${SSHD_MAIN}.vault-ca.XXXXXX")"
  RUN sh -c "sed '\|$INCLUDE_BEGIN|,\|$INCLUDE_END|d' \"\$1\" > \"\$2\"" _ "$SSHD_MAIN" "$tmp_sshd"
  RUN chmod --reference="$SSHD_MAIN" "$tmp_sshd"
  RUN chown --reference="$SSHD_MAIN" "$tmp_sshd"
  RUN mv "$tmp_sshd" "$SSHD_MAIN"
  INCLUDE_REMOVED=1
fi

_rollback_fired=0
rollback() {
  (( _rollback_fired )) && return
  _rollback_fired=1
  trap - ERR
  echo "  Rolling back changes on $(hostname -s 2>/dev/null || hostname)..." >&2
  local f
  for f in "${BACKED_UP[@]}"; do
    RUN mv "${f}${SUFFIX}" "$f" 2>/dev/null || true
  done
  if (( SSHD_MAIN_BACKED_UP )) && RUN test -f "${SSHD_MAIN}${SUFFIX}"; then
    RUN mv "${SSHD_MAIN}${SUFFIX}" "$SSHD_MAIN" 2>/dev/null || true
  fi
}

trap 'rollback; exit 1' ERR

RUN rm -f "$TRUST_PUB" "$TRUST_CONF" "$TRUST_KRL"

if ! RUN sshd -t 2>&1; then
  echo "  ERROR: sshd -t failed after removing CA trust." >&2
  rollback
  exit 1
fi

# Debian target assumption: OpenSSH service name is 'ssh' here, not 'sshd'.
RUN systemctl reload ssh 2>/dev/null || RUN systemctl restart ssh

trap - ERR
for f in "${BACKED_UP[@]}"; do
  RUN rm -f "${f}${SUFFIX}" 2>/dev/null || true
done
if (( SSHD_MAIN_BACKED_UP )); then
  RUN rm -f "${SSHD_MAIN}${SUFFIX}" 2>/dev/null || true
fi

if (( INCLUDE_REMOVED )); then
  echo "  Removed vault-ca Include block from $SSHD_MAIN"
fi
echo "  CA trust removed on $(hostname -s 2>/dev/null || hostname)"
UNTRUST_BODY
}

_emit_krl_script() {
  local krl_b64
  # Debian/coreutils assumption: base64 supports -w0 (no line-wrap).
  krl_b64="$(sudo -n -u sshca "$KRL_BIN" cat-krl | base64 -w0)"
  local stamp; stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat <<KRL_HEADER
#!/usr/bin/env bash
# vault-ca KRL installer — generated ${stamp}
# Replaces the target's RevokedKeys file with the vault's current KRL.
set -Eeuo pipefail
KRL_B64='${krl_b64}'
KRL_HEADER

  cat <<'KRL_BODY'
TRUST_KRL="/etc/ssh/ssh-ca-krl"
SUFFIX=".vault-ca.pre-$(date +%s)"

RUN() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

_backed_up=0
if RUN test -f "$TRUST_KRL"; then
  RUN cp -p "$TRUST_KRL" "${TRUST_KRL}${SUFFIX}"
  _backed_up=1
fi

_rollback_fired=0
rollback() {
  (( _rollback_fired )) && return
  _rollback_fired=1
  trap - ERR
  if (( _backed_up )) && RUN test -f "${TRUST_KRL}${SUFFIX}"; then
    RUN mv "${TRUST_KRL}${SUFFIX}" "$TRUST_KRL" 2>/dev/null || true
  else
    RUN rm -f "$TRUST_KRL" 2>/dev/null || true
  fi
}

trap 'rollback; exit 1' ERR

if [[ -n "$KRL_B64" ]]; then
  printf '%s' "$KRL_B64" | base64 -d | RUN tee "$TRUST_KRL" >/dev/null
else
  # Empty KRL: write an empty file so sshd still has a readable RevokedKeys.
  RUN tee "$TRUST_KRL" </dev/null >/dev/null
fi
RUN chmod 0644 "$TRUST_KRL"

if ! RUN sshd -t 2>&1; then
  echo "  ERROR: sshd -t failed after writing KRL." >&2
  rollback
  exit 1
fi

# Debian target assumption: OpenSSH service name is 'ssh' here, not 'sshd'.
RUN systemctl reload ssh 2>/dev/null || RUN systemctl restart ssh

trap - ERR
RUN rm -f "${TRUST_KRL}${SUFFIX}" 2>/dev/null || true

echo "  KRL deployed on $(hostname -s 2>/dev/null || hostname)"
KRL_BODY
}

cmd_trust_bundle()   { _emit_trust_script; }
cmd_untrust_bundle() { _emit_untrust_script; }
cmd_krl_bundle()     { _emit_krl_script; }

_pipe_bundle_to_target() {
  # Convenience: build a bundle and pipe it into ssh <target> 'bash -s'.
  # Requires the invoking user to have outbound SSH creds to <target>.
  local emitter="$1" target="$2" port="$3"
  [[ -n "$target" ]] || die "target required (user@host)"
  local ssh_opts=(-o BatchMode=no)
  [[ -n "$port" ]] && ssh_opts+=(-p "$port")
  "$emitter" | ssh "${ssh_opts[@]}" "$target" 'bash -s'
}

cmd_trust() {
  local target="${1:-}" port=""
  [[ -n "$target" ]] || die "Usage: vault-ca trust <user@host> [--port N]
  Or pipe a bundle from your workstation (no outbound SSH needed on vault):
    __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca trust-bundle | ssh <user@host> 'bash -s'"
  shift
  while (( $# > 0 )); do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -n "$port" ]] && { [[ "$port" =~ ^[0-9]+$ ]] || die "invalid --port"; }
  _pipe_bundle_to_target _emit_trust_script "$target" "$port"
}

cmd_untrust() {
  local target="${1:-}" port=""
  [[ -n "$target" ]] || die "Usage: vault-ca untrust <user@host> [--port N]
  Or pipe a bundle from your workstation (no outbound SSH needed on vault):
    __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca untrust-bundle | ssh <user@host> 'bash -s'"
  shift
  while (( $# > 0 )); do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -n "$port" ]] && { [[ "$port" =~ ^[0-9]+$ ]] || die "invalid --port"; }
  _pipe_bundle_to_target _emit_untrust_script "$target" "$port"
}

cmd_krl_deploy() {
  local target="${1:-}" port=""
  [[ -n "$target" ]] || die "Usage: vault-ca krl deploy <user@host> [--port N]
  Or pipe a bundle from your workstation (no outbound SSH needed on vault):
    __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca krl-bundle | ssh <user@host> 'bash -s'"
  shift
  while (( $# > 0 )); do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -n "$port" ]] && { [[ "$port" =~ ^[0-9]+$ ]] || die "invalid --port"; }
  _pipe_bundle_to_target _emit_krl_script "$target" "$port"
}

# ── client-wrapper ────────────────────────────────────────────────────────────
cmd_client_wrapper() {
  [[ -f "$WRAPPER_SRC" ]] || die "wrapper not installed at $WRAPPER_SRC"
  cat "$WRAPPER_SRC"
}

# ── revoke / krl ──────────────────────────────────────────────────────────────
cmd_revoke() {
  local serial="${1:-}"
  [[ -n "$serial" ]] || die "Usage: vault-ca revoke <serial>"
  [[ "$serial" =~ ^[0-9]+$ ]] || die "serial must be numeric"
  local operator; operator="$(operator_name)"
  sudo -n -u sshca "$KRL_BIN" add-serial "$serial" "$operator"
  echo "  Deploy to targets (from workstation):"
  echo "    __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca krl-bundle | ssh <user@host> 'bash -s'"
}

cmd_unrevoke() {
  local serial="${1:-}"
  [[ -n "$serial" ]] || die "Usage: vault-ca unrevoke <serial>"
  [[ "$serial" =~ ^[0-9]+$ ]] || die "serial must be numeric"
  local operator; operator="$(operator_name)"
  sudo -n -u sshca "$KRL_BIN" unrevoke-serial "$serial" "$operator"
  echo "  Deploy to targets (from workstation):"
  echo "    __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca krl-bundle | ssh <user@host> 'bash -s'"
}

cmd_krl_show() {
  sudo -n -u sshca "$KRL_BIN" show
}

cmd_version() { echo "vault-ca 1.0.0"; }

# ── dispatch ──────────────────────────────────────────────────────────────────
cmd="${1:-help}"
shift || true
case "$cmd" in
  help|-h|--help)    usage ;;
  init)              cmd_init "$@" ;;
  sign)              cmd_sign "$@" ;;
  list)              cmd_list "$@" ;;
  show-ca-pub)       cmd_show_ca_pub "$@" ;;
  fingerprint)       cmd_fingerprint "$@" ;;
  trust)             cmd_trust "$@" ;;
  untrust)           cmd_untrust "$@" ;;
  trust-bundle)      cmd_trust_bundle "$@" ;;
  untrust-bundle)    cmd_untrust_bundle "$@" ;;
  krl-bundle)        cmd_krl_bundle "$@" ;;
  client-wrapper)    cmd_client_wrapper "$@" ;;
  revoke)            cmd_revoke "$@" ;;
  unrevoke)          cmd_unrevoke "$@" ;;
  krl)
    sub="${1:-}"; shift || true
    case "$sub" in
      show)    cmd_krl_show "$@" ;;
      deploy)  cmd_krl_deploy "$@" ;;
      *)       die "krl subcommand must be 'show' or 'deploy'" ;;
    esac
    ;;
  version)           cmd_version ;;
  *)                 usage; exit 1 ;;
esac
VAULTCA_EOF

# Substitute placeholders with this vault's actual IP and admin user so
# help text, redeploy reminders, and error messages in the in-CT helper
# show copy-paste-ready commands rather than a placeholder hostname.
# Same rationale as the workstation wrapper: avoid a DNS dependency.
sed -i \
  -e "s|__VAULT_HOST__|${CT_IP}|g" \
  -e "s|__VAULT_USER__|${ADMIN_USER}|g" \
  -e "s|__SSH_CMD__|${SSH_CMD_STR}|g" \
  "$VAULT_CA_SRC"

pct push "$CT_ID" "$VAULT_CA_SRC" "$VAULT_CA_BIN" --perms 0755
pct exec "$CT_ID" -- chown root:root "$VAULT_CA_BIN"

# ── Vault-CA: build workstation wrapper (ca-sign) on host, push into CT ───────
# Stored at /usr/local/share/vault-ca/ca-sign on the vault, fetched by admins
# via `ssh <admin>@<vault-ip> vault-ca client-wrapper > ~/.local/bin/ca-sign`.
# The wrapper is templated at creation time with the actual vault IP and
# admin user (placeholders __VAULT_HOST__ / __VAULT_USER__).
WRAPPER_SRC_FILE="${HOST_TMPDIR}/ca-sign"

cat > "$WRAPPER_SRC_FILE" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# ca-sign — request a fresh SSH user certificate from the vault-ca service.
#
# Installation (on your workstation):
#   __SSH_CMD__ __VAULT_USER__@__VAULT_HOST__ vault-ca client-wrapper > ~/.local/bin/ca-sign
#   chmod +x ~/.local/bin/ca-sign
#
# Usage:
#   ca-sign                                    # defaults: ~/.ssh/id_ed25519, __DEFAULT_VALIDITY__, host label
#   ca-sign -k ~/.ssh/work_ed25519             # different key
#   ca-sign -V +4h -n root,admin               # custom validity + principals
#   ca-sign -k ~/.ssh/id_ed25519 -l laptop-a -V +12h -n ubuntu,root
#
# Options:
#   -k, --key <path>          private-key path (default: $HOME/.ssh/id_ed25519)
#                             (you may pass the .pub path; the private path is inferred)
#   -l, --label <str>         short identity label baked into the cert (default: hostname -s)
#   -V, --validity <spec>     e.g. +8h, +30m, +7d (default: __DEFAULT_VALIDITY__; max enforced by vault)
#   -n, --principals <list>   comma-separated login names (default: vault's default)
#   -h, --help                show this help
#
# Environment overrides:
#   VAULT_CA_HOST     vault address — hostname or IP (default: __VAULT_HOST__,
#                     the CT's IP baked in at install time so first-time
#                     bootstrap does not depend on DNS)
#   VAULT_CA_USER     admin user on the vault (default: __VAULT_USER__)
#   VAULT_CA_PORT     SSH port (default: __VAULT_PORT__)
#
# Note:
#   On DHCP networks the baked-in IP can drift. Reserve the CT IP on your
#   DHCP server, or add a DNS record for the vault and export
#   VAULT_CA_HOST=<dns-name> in your shell profile.
#
# Writes:
#   <key>-cert.pub next to the private key. OpenSSH picks it up automatically
#   when you use that key — no extra config on the client.
set -euo pipefail

VAULT_HOST="${VAULT_CA_HOST:-__VAULT_HOST__}"
VAULT_USER="${VAULT_CA_USER:-__VAULT_USER__}"
VAULT_PORT="${VAULT_CA_PORT:-__VAULT_PORT__}"

KEY_PATH="$HOME/.ssh/id_ed25519"
LABEL="$(hostname -s 2>/dev/null || hostname)"
VALIDITY="__DEFAULT_VALIDITY__"
PRINCIPALS=""

usage() { sed -n '2,/^set -euo/ p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/ d'; exit 0; }

while (( $# > 0 )); do
  case "$1" in
    -k|--key)        KEY_PATH="$2";    shift 2 ;;
    -l|--label)      LABEL="$2";       shift 2 ;;
    -V|--validity)   VALIDITY="$2";    shift 2 ;;
    -n|--principals) PRINCIPALS="$2";  shift 2 ;;
    -h|--help)       usage ;;
    --)              shift; break ;;
    -*)              echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    *)               # Allow legacy positional form: key [label] [validity]
                     KEY_PATH="$1"; shift
                     [[ $# -gt 0 ]] && { LABEL="$1"; shift; }
                     [[ $# -gt 0 ]] && { VALIDITY="$1"; shift; }
                     ;;
  esac
done

# Normalise: accept either the private key path or the .pub path.
if [[ "$KEY_PATH" == *.pub ]]; then
  PUB="$KEY_PATH"
  PRIV="${KEY_PATH%.pub}"
else
  PRIV="$KEY_PATH"
  PUB="${KEY_PATH}.pub"
fi
CERT="${PRIV}-cert.pub"

[[ -f "$PUB"  ]] || { echo "ERROR: public key not found: $PUB" >&2; exit 1; }
[[ -f "$PRIV" ]] || echo "  note: private key ${PRIV} not found; OpenSSH won't pick up ${CERT} without it" >&2

# Build remote argv. Principals is only passed if the user set it — otherwise
# the vault's configured default is used.
remote_args=(vault-ca sign "$LABEL" -V "$VALIDITY")
[[ -n "$PRINCIPALS" ]] && remote_args+=(-n "$PRINCIPALS")
remote_args+=(-)

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

ssh -p "$VAULT_PORT" -o BatchMode=yes "$VAULT_USER@$VAULT_HOST" \
    "${remote_args[@]}" < "$PUB" > "$TMP"

# Sanity check: response must look like a certificate. The (sk-)? prefix
# accepts FIDO/U2F-backed cert algorithms (sk-ssh-ed25519-cert-v01@openssh.com,
# sk-ecdsa-sha2-nistp256-cert-v01@openssh.com).
if ! head -n1 "$TMP" | grep -qE '^(sk-)?(ssh|ecdsa)-[a-z0-9-]+-cert-v[0-9]+@openssh\.com '; then
  echo "ERROR: vault response was not a certificate:" >&2
  sed 's/^/  /' "$TMP" >&2
  exit 1
fi

install -m 0644 "$TMP" "$CERT"
echo "Signed: $CERT"
ssh-keygen -L -f "$CERT" \
  | grep -E '^[[:space:]]+(Valid|Principals|Key ID|Critical|Extensions|Serial)' \
  | sed 's/^/  /'
WRAPPER_EOF

# Substitute placeholders with this vault's actual IP and admin user.
# We use CT_IP rather than HN so first bootstrap does not depend on
# DNS resolving the vault hostname from the workstation; users can
# still override at runtime via VAULT_CA_HOST / VAULT_CA_USER / VAULT_CA_PORT.
# Using '|' as the sed delimiter so values with '/' don't break the pattern.
# Both values are already validated.
sed -i \
  -e "s|__VAULT_HOST__|${CT_IP}|g" \
  -e "s|__VAULT_USER__|${ADMIN_USER}|g" \
  -e "s|__VAULT_PORT__|${SSH_PORT}|g" \
  -e "s|__SSH_CMD__|${SSH_CMD_STR}|g" \
  -e "s|__DEFAULT_VALIDITY__|${CA_DEFAULT_VALIDITY}|g" \
  "$WRAPPER_SRC_FILE"

pct push "$CT_ID" "$WRAPPER_SRC_FILE" "$VAULT_CA_WRAPPER" --perms 0755
pct exec "$CT_ID" -- chown root:root "$VAULT_CA_WRAPPER"

# ── Vault-CA: sudoers drop-in ─────────────────────────────────────────────────
# Admin is allowed to invoke exactly two binaries as sshca, with any
# arguments — both binaries validate their own input strictly.
SUDOERS_SRC="${HOST_TMPDIR}/vault-ca-sudoers"
cat > "$SUDOERS_SRC" <<EOF2
# /etc/sudoers.d/vault-ca — privileged bridge for ${ADMIN_USER} -> sshca.
# Scoped to the two vault-ca binaries; they strictly validate their own args.
${ADMIN_USER} ALL=(sshca) NOPASSWD: ${VAULT_CA_SIGNER}, ${VAULT_CA_KRL_HELPER}
EOF2

pct push "$CT_ID" "$SUDOERS_SRC" "$VAULT_CA_SUDOERS" --perms 0440
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  chown root:root '${VAULT_CA_SUDOERS}'
  if ! visudo -cf '${VAULT_CA_SUDOERS}' >/dev/null; then
    echo '  ERROR: sudoers syntax check failed; removing drop-in.' >&2
    rm -f '${VAULT_CA_SUDOERS}'
    exit 1
  fi
  echo '  Sudoers drop-in validated.'
"

# ── Vault-CA: initialise the CA (run once) ────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  if [[ -f '${CA_KEY}' ]]; then
    echo '  CA already present — skipping init.'
  else
    '${VAULT_CA_BIN}' init
  fi
"

# ── Vault-CA: sshd hardening drop-in ──────────────────────────────────────────
SSHD_SRC="${HOST_TMPDIR}/10-vault-ca-hardening.conf"
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

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  mkdir -p /etc/ssh/sshd_config.d
  # Require a *.conf glob — same rule trust-bundle enforces on targets.
  # A narrower Include (single specific file) would silently orphan our
  # drop-in, so treat it as 'no matching Include' and append our own;
  # sshd accepts multiple Include directives fine.
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+(/etc/ssh/)?sshd_config\.d/\*\.conf([[:space:]]|\$)' /etc/ssh/sshd_config; then
    printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
  fi
"

pct push "$CT_ID" "$SSHD_SRC" "$SSHD_DROPIN_PATH" --perms 0644

pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  if ! sshd -t; then
    echo '  ERROR: sshd configuration test failed. Removing vault-ca drop-in.' >&2
    rm -f '${SSHD_DROPIN_PATH}'
    exit 1
  fi
  systemctl enable ssh >/dev/null
  systemctl restart ssh
  echo '  SSH hardened for user: ${ADMIN_USER}'
"

# ── Vault-CA: lock root password (optional) ───────────────────────────────────
if [[ "$LOCK_ROOT_PASSWORD" -eq 1 ]]; then
  pct exec "$CT_ID" -- bash -lc '
    set -euo pipefail
    passwd -l root >/dev/null
    echo "  Root password locked"
  '
fi

# ── Vault-CA: verification ────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  systemctl is-active --quiet ssh || { echo '  ERROR: ssh service is not active.' >&2; exit 1; }
  if command -v ss >/dev/null 2>&1; then
    ss -H -tln \"sport = :${SSH_PORT}\" | grep -q . \
      || { echo '  ERROR: nothing listening on port ${SSH_PORT}.' >&2; exit 1; }
  fi
  [[ -f '${CA_KEY}' && -f '${CA_PUB}' ]] \
    || { echo '  ERROR: CA material missing after init.' >&2; exit 1; }
  [[ \"\$(stat -c '%U:%G %a' '${CA_KEY}')\" == 'sshca:sshca 600' ]] \
    || { echo '  ERROR: CA private key has wrong ownership/mode.' >&2; exit 1; }

  # Probe the sudoers path by invoking the signer as admin with no arguments.
  # The signer, running as sshca, will reject with 'ERROR: invalid identity'.
  # If sudo denies the transition, the output begins with 'sudo:' instead.
  # Exit code is 1 either way — we disambiguate on stderr content.
  probe_out=\"\$(su -s /bin/bash '${ADMIN_USER}' -c \\
    'sudo -n -u sshca ${VAULT_CA_SIGNER} 2>&1 || true')\"
  if printf '%s' \"\$probe_out\" | grep -qi '^sudo:'; then
    echo '  ERROR: sudo denied admin -> sshca transition:' >&2
    printf '%s\n' \"\$probe_out\" | sed 's/^/    /' >&2
    exit 1
  fi
  if ! printf '%s' \"\$probe_out\" | grep -q 'ERROR: invalid identity'; then
    echo '  ERROR: signer did not respond as expected. Output was:' >&2
    printf '%s\n' \"\$probe_out\" | sed 's/^/    /' >&2
    exit 1
  fi

  # Smoke-test the generated helper outputs admins will actually use.
  # Each invocation exercises a different render path:
  #   help            — placeholder substitution (__SSH_CMD__ / __VAULT_USER__ / __VAULT_HOST__)
  #   show-ca-pub     — CA_PUB readable, ownership/mode intact
  #   client-wrapper  — WRAPPER_SRC installed and readable
  #   trust-bundle    — CA_PUB → base64 → script template
  #   krl-bundle      — sudo -u sshca → KRL_BIN cat-krl → base64 → script template
  # A failure here means an operator-facing command is broken at deploy time,
  # which is a better readiness signal than static lint.
  '${VAULT_CA_BIN}' help >/dev/null \
    || { echo '  ERROR: vault-ca help failed.' >&2; exit 1; }
  '${VAULT_CA_BIN}' show-ca-pub >/dev/null \
    || { echo '  ERROR: vault-ca show-ca-pub failed.' >&2; exit 1; }
  '${VAULT_CA_BIN}' client-wrapper >/dev/null \
    || { echo '  ERROR: vault-ca client-wrapper failed.' >&2; exit 1; }
  '${VAULT_CA_BIN}' trust-bundle >/dev/null \
    || { echo '  ERROR: vault-ca trust-bundle failed.' >&2; exit 1; }
  '${VAULT_CA_BIN}' krl-bundle >/dev/null \
    || { echo '  ERROR: vault-ca krl-bundle failed.' >&2; exit 1; }

  echo '  Verification: sshd active, CA initialised, admin->sshca sudo path OK, helper outputs render.'
"

# ── Cleanup packages ──────────────────────────────────────────────────────────
# Keep man-db + manpages — ssh(1), ssh-keygen(1), sshd_config(5) belong on
# this host for on-box debugging.
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get -y autoremove
  apt-get -y clean
'

# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*

  cat > /etc/update-motd.d/00-header <<'EOF2'
#!/bin/sh
printf '\n  Vault-CA LXC — SSH Certificate Authority\n'
printf '  ─────────────────────────────────────────\n'
EOF2

  cat > /etc/update-motd.d/10-sysinfo <<'EOF2'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' \"\$(hostname)\"
printf '  IP:        %s\n' \"\${ip:-n/a}\"
printf '  Uptime:    %s\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
EOF2

  cat > /etc/update-motd.d/30-vault-ca <<'EOF2'
#!/bin/sh
printf '\n'
printf '  Signing helper:  vault-ca help\n'
printf '  CA pubkey:       vault-ca show-ca-pub\n'
printf '  CA fingerprint:  vault-ca fingerprint\n'
printf '\n'
printf '  Workstation wrapper (run on your workstation):\n'
printf '    ssh${SSH_PORT_ARG} $ADMIN_USER@${CT_IP} vault-ca client-wrapper \\\\\n'
printf '        > ~/.local/bin/ca-sign && chmod +x ~/.local/bin/ca-sign\n'
printf '\n'
printf '  Trust the CA on a target (from workstation — preferred):\n'
printf '    ssh${SSH_PORT_ARG} $ADMIN_USER@${CT_IP} vault-ca trust-bundle \\\\\n'
printf '        | ssh root@target.lab '\\''bash -s'\\''\n'
printf '\n'
printf '  Revoke a cert and push the updated KRL:\n'
printf '    ssh${SSH_PORT_ARG} $ADMIN_USER@${CT_IP} vault-ca revoke <serial>\n'
printf '    ssh${SSH_PORT_ARG} $ADMIN_USER@${CT_IP} vault-ca krl-bundle \\\\\n'
printf '        | ssh root@target.lab '\\''bash -s'\\''\n'
printf '\n'
printf '  Inbound SSH to this vault-ca CT is pubkey-only.\n'
printf '  Authorized keys: /home/$ADMIN_USER/.ssh/authorized_keys\n'
EOF2

  cat > /etc/update-motd.d/99-footer <<'EOF2'
#!/bin/sh
printf '  ─────────────────────────────────────────\n\n'
EOF2

  chmod +x /etc/update-motd.d/*
"

pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'

# ── Proxmox UI description ────────────────────────────────────────────────────
# Minimal at-a-glance description: a one-line header outside <details>, and
# inside <details> a sequenced, command-first walkthrough — workstation
# setup first (authorize key, install ca-sign), then per-target onboarding,
# then daily use. The trust installer and ca-sign wrapper source are kept
# at the bottom as paste-fallbacks for isolated workstations/targets.
# All three (CA pubkey, trust installer, wrapper) are fetched from the CT
# so the description stays authoritative after any in-CT change — in
# particular, the embedded trust installer is byte-for-byte the output of
# `vault-ca trust-bundle`, so the documented fallback matches the real
# installer (backup, FORCE gate, sshd_config Include handling, rollback).
# Everything else (fingerprint, audit log path, defaults) is surfaced by
# \`vault-ca help\` and the post-install bootstrap summary.
CA_SIGN_CONTENT="$(pct exec "$CT_ID" -- cat "${VAULT_CA_WRAPPER}")"
TRUST_BUNDLE_CONTENT="$(pct exec "$CT_ID" -- "${VAULT_CA_BIN}" trust-bundle)"

# Heredoc is unquoted on purpose: \${VARS} expand once, and \` gives literal
# backticks for the markdown code fences. The interpolated wrapper and
# trust-bundle contents are NOT re-parsed — any \$VAR or \$(...) inside
# them stays literal as variable content. (Trust-bundle itself contains
# heredoc delimiters like TRUST_BODY / CONF; those are inert at this
# layer and only become active when the user pastes the block on a target.)
VAULT_CA_DESC="$(cat <<EOF_DESC
Vault-CA LXC (${CT_IP}) — ssh${SSH_PORT_ARG} ${ADMIN_USER}@${CT_IP}
<details><summary>Setup &amp; onboarding commands</summary>

### 1. Authorize your workstation key on the vault (one time)

Run on your workstation — prints your pubkey, copy it:
\`\`\`bash
cat ~/.ssh/id_ed25519.pub
\`\`\`

If no key exists yet (or \`ssh-keygen\` is missing), create one first:
\`\`\`bash
apt install openssh-client
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
\`\`\`

Run on the PVE host — open the vault console:
\`\`\`bash
pct console ${CT_ID}
\`\`\`

Log in as \`${ADMIN_USER}\` (password set during deploy), then inside the console:
\`\`\`bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys        # paste the pubkey line, save
chmod 600 ~/.ssh/authorized_keys
exit
\`\`\`

Exit the console with \`Ctrl-a q\`. Verify from your workstation:
\`\`\`bash
${SSH_CMD_STR} ${ADMIN_USER}@${CT_IP} hostname
\`\`\`

Should succeed without a password prompt.

### 2. Install ca-sign on your workstation (one time)

\`\`\`bash
mkdir -p ~/.local/bin
${SSH_CMD_STR} ${ADMIN_USER}@${CT_IP} vault-ca client-wrapper > ~/.local/bin/ca-sign
chmod +x ~/.local/bin/ca-sign
echo \$PATH | tr ':' '\n' | grep -q "\$HOME/.local/bin" \\
  || echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.bashrc
source ~/.bashrc
ca-sign --help
\`\`\`

### 3. Onboard each target (one time, per target)

**Preferred — automated one-liner.** Run from your workstation. Requires SSH
access to both the vault (as \`${ADMIN_USER}\`, set up in step 1) and the target
(as \`root\`). Replace \`<target-ip>\` with the actual target:
\`\`\`bash
${SSH_CMD_STR} ${ADMIN_USER}@${CT_IP} vault-ca trust-bundle | ssh root@<target-ip> 'bash -s'
\`\`\`

**Fallback — manual paste.** Use when the workstation can't SSH to the target
(isolated network, no sshd yet, bootstrapping from console, etc.). Get a root
shell on the target (SSH, \`pct console\`, or physical console), then paste the
**Trust installer** from the appendix below. The installer is byte-for-byte
equivalent to what \`vault-ca trust-bundle\` emits over SSH — the CA pubkey is
baked in, it backs up what it touches, refuses to clobber a different CA
(unless \`FORCE=1\`), adds the \`Include\` line to \`sshd_config\` if missing,
and rolls back on any failure.

### 4. Daily use

\`\`\`bash
ca-sign                    # fetch fresh 8h certificate
ssh root@<target-ip>       # OpenSSH picks up the cert automatically
\`\`\`

### Appendix — Trust installer (fallback for step 3)

Paste this into a root shell on the target. Equivalent to running
\`${SSH_CMD_STR} ${ADMIN_USER}@${CT_IP} vault-ca trust-bundle | ssh root@<target> 'bash -s'\`
from a workstation that can reach both sides.

\`\`\`bash
${TRUST_BUNDLE_CONTENT}
\`\`\`

### Appendix — ca-sign wrapper source

Fallback for workstations that cannot SSH to the vault. Save as
\`~/.local/bin/ca-sign\` and \`chmod +x\`. Otherwise use step 2 above.

\`\`\`bash
${CA_SIGN_CONTENT}
\`\`\`

</details>
EOF_DESC
)"
pct set "$CT_ID" --description "$VAULT_CA_DESC"

# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1

# ── Host tmpdir cleanup (success path) ────────────────────────────────────────
rm -rf "$HOST_TMPDIR"
unset HOST_TMPDIR

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  Done."
echo "  CT ID:          $CT_ID"
echo "  CT IP:          $CT_IP"
echo "  Admin user:     $ADMIN_USER"
echo "  SSH port:       $SSH_PORT"
echo "  Root locked:    $([ "$LOCK_ROOT_PASSWORD" -eq 1 ] && echo yes || echo no)"
echo "  CA owner:       sshca (system user)"
echo "  CA key:         $CA_KEY"
echo "  CA pub:         $CA_PUB"
if pct exec "$CT_ID" -- bash -lc "[[ -f '${CA_PUB}' ]]" 2>/dev/null; then
  echo "  CA fingerprint: $(pct exec "$CT_ID" -- bash -lc "ssh-keygen -l -E sha256 -f '${CA_PUB}'" 2>/dev/null | head -n1)"
fi
echo "  Helper:         $VAULT_CA_BIN (inside CT)"
echo "  Audit log:      $AUDIT_LOG (inside CT)"
echo ""
echo "  Bootstrap steps (in order, run from your workstation unless noted):"
echo ""
if [[ -n "$ADMIN_PUBKEY_LINE" ]]; then
  echo "    1) Authorized key was seeded at deploy — no console step needed."
  echo ""
else
  echo "    1) On the PVE host, add an inbound login key for $ADMIN_USER:"
  echo "         pct console $CT_ID"
  echo "         (login as $ADMIN_USER, paste your pubkey into ~/.ssh/authorized_keys)"
  echo ""
fi
echo "    2) Verify you can SSH in:"
echo "         ssh${SSH_PORT_ARG} $ADMIN_USER@$CT_IP hostname"
echo ""
echo "    3) Install the workstation wrapper:"
echo "         ssh${SSH_PORT_ARG} $ADMIN_USER@$CT_IP vault-ca client-wrapper \\"
echo "             > ~/.local/bin/ca-sign"
echo "         chmod +x ~/.local/bin/ca-sign"
echo ""
echo "    4) Sign a cert for today (default: ${CA_DEFAULT_VALIDITY}, principals ${CA_DEFAULT_PRINCIPALS}):"
echo "         ca-sign"
echo "       Custom: ca-sign -k ~/.ssh/work_ed25519 -V +4h -n ubuntu,root"
echo ""
echo "    5) Trust the CA on a target (no outbound SSH needed on the vault):"
echo "         ssh${SSH_PORT_ARG} $ADMIN_USER@$CT_IP vault-ca trust-bundle \\"
echo "             | ssh root@target.lab 'bash -s'"
echo ""
echo "    6) Log into the target — OpenSSH presents the cert automatically:"
echo "         ssh root@target.lab"
echo ""
echo "  Revocation:"
echo "    ssh${SSH_PORT_ARG} $ADMIN_USER@$CT_IP vault-ca revoke <serial>"
echo "    ssh${SSH_PORT_ARG} $ADMIN_USER@$CT_IP vault-ca krl-bundle | ssh root@target.lab 'bash -s'"
echo ""
echo "  Fallback if SSH is broken:"
echo "    pct enter $CT_ID"
echo "    su - $ADMIN_USER"
echo ""
