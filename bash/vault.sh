#!/usr/bin/env bash
set -Eeuo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
ADMIN_USER="admin"
ADMIN_COMMENT="Vault User"
ADMIN_SHELL="/bin/bash"
ADMIN_GROUPS=(sudo)

# SSH service on the vault CT itself
SSH_PORT=22
SSH_LISTEN_ADDRESS=""               # blank = all addresses
ALLOW_TCP_FORWARDING=0
ALLOW_AGENT_FORWARDING=0
ALLOW_X11_FORWARDING=0
LOCK_ROOT_PASSWORD=1                # local root password lock; pct enter still works

# Helper / MOTD
VAULT_HELPER_PATH="/usr/local/bin/vault-key"
MOTD_HELPER="/etc/update-motd.d/70-vault-hint"

# Packages
PACKAGES=(
  openssh-server
  openssh-client
  sudo
  ca-certificates
)

# ── Trap ──────────────────────────────────────────────────────────────────────
trap 'rc=$?; echo "  ERROR: failed (rc=$rc) near line ${BASH_LINENO[0]:-?}" >&2; echo "  Command: $BASH_COMMAND" >&2; exit "$rc"' ERR
trap 'rc=$?; echo "  Interrupted (rc=$rc)" >&2; echo "  Command: $BASH_COMMAND" >&2; exit "$rc"' INT TERM

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run this script as root inside the LXC." >&2; exit 1; }

for cmd in apt-get systemctl ssh-keygen install awk grep getent useradd usermod groupadd chown chmod mkdir mktemp passwd chpasswd id; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || {
  echo "  ERROR: ADMIN_USER must match ^[a-z_][a-z0-9_-]{0,31}$" >&2
  exit 1
}
[[ "$ADMIN_USER" != "root" ]] || { echo "  ERROR: ADMIN_USER must not be root." >&2; exit 1; }

[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || {
  echo "  ERROR: SSH_PORT must be between 1 and 65535." >&2
  exit 1
}

[[ "$ALLOW_TCP_FORWARDING" =~ ^[01]$ ]] || { echo "  ERROR: ALLOW_TCP_FORWARDING must be 0 or 1." >&2; exit 1; }
[[ "$ALLOW_AGENT_FORWARDING" =~ ^[01]$ ]] || { echo "  ERROR: ALLOW_AGENT_FORWARDING must be 0 or 1." >&2; exit 1; }
[[ "$ALLOW_X11_FORWARDING" =~ ^[01]$ ]] || { echo "  ERROR: ALLOW_X11_FORWARDING must be 0 or 1." >&2; exit 1; }
[[ "$LOCK_ROOT_PASSWORD" =~ ^[01]$ ]] || { echo "  ERROR: LOCK_ROOT_PASSWORD must be 0 or 1." >&2; exit 1; }

if [[ -n "$SSH_LISTEN_ADDRESS" ]] && ! [[ "$SSH_LISTEN_ADDRESS" =~ ^[A-Za-z0-9:._-]+$ ]]; then
  echo "  ERROR: SSH_LISTEN_ADDRESS contains invalid characters." >&2
  exit 1
fi

# ── Summary & confirm ─────────────────────────────────────────────────────────
cat <<EOF2

  Vault LXC Hardening — Configuration
  ────────────────────────────────────────
  Admin user:          $ADMIN_USER
  Admin shell:         $ADMIN_SHELL
  SSH port:            $SSH_PORT
  Lock root password:  $([ "$LOCK_ROOT_PASSWORD" -eq 1 ] && echo 'yes' || echo 'no')
  TCP forwarding:      $([ "$ALLOW_TCP_FORWARDING" -eq 1 ] && echo 'yes' || echo 'no')
  Agent forwarding:    $([ "$ALLOW_AGENT_FORWARDING" -eq 1 ] && echo 'yes' || echo 'no')
  X11 forwarding:      $([ "$ALLOW_X11_FORWARDING" -eq 1 ] && echo 'yes' || echo 'no')
  Helper path:         $VAULT_HELPER_PATH
  ────────────────────────────────────────
  This script will:
    • create or update the local admin user
    • set a normal local password for that user
    • install OpenSSH if needed
    • harden sshd so only $ADMIN_USER may log in
    • disable root SSH access
    • scaffold ~/.ssh and install the vault-key helper
    • add a MOTD hint for key management

  After this script runs, inbound SSH to this vault CT stays locked
  until you add a public key to /home/$ADMIN_USER/.ssh/authorized_keys.
  pct enter remains available.

EOF2

read -r -p "  Continue with these settings? [y/N]: " response
case "$response" in
  [yY][eE][sS]|[yY]) ;;
  *)
    echo ""
    echo "  Aborted. Edit the Config section at the top of the script and re-run."
    exit 0
    ;;
esac

echo ""

# ── User password prompt ──────────────────────────────────────────────────────
ADMIN_PASSWORD=""
while true; do
  read -r -s -p "  Set password for ${ADMIN_USER}: " PW1; echo
  [[ -n "$PW1" ]] || { echo "  Password cannot be blank."; continue; }
  [[ "$PW1" != *" "* ]] || { echo "  Password cannot contain spaces."; continue; }
  (( ${#PW1} >= 8 )) || { echo "  Password must be at least 8 characters."; continue; }

  read -r -s -p "  Verify password for ${ADMIN_USER}: " PW2; echo
  [[ "$PW1" == "$PW2" ]] || { echo "  Passwords do not match. Try again."; continue; }

  ADMIN_PASSWORD="$PW1"
  unset PW1 PW2
  break
done

# ── Packages ──────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends "${PACKAGES[@]}"

# ── User setup ────────────────────────────────────────────────────────────────
if ! getent passwd "$ADMIN_USER" >/dev/null 2>&1; then
  useradd -m -s "$ADMIN_SHELL" -c "$ADMIN_COMMENT" "$ADMIN_USER"
  echo "  Created user: $ADMIN_USER"
else
  usermod -s "$ADMIN_SHELL" "$ADMIN_USER"
  echo "  User already exists: $ADMIN_USER"
fi

for grp in "${ADMIN_GROUPS[@]}"; do
  getent group "$grp" >/dev/null 2>&1 || groupadd "$grp"
  usermod -aG "$grp" "$ADMIN_USER"
done

echo "$ADMIN_USER:$ADMIN_PASSWORD" | chpasswd
unset ADMIN_PASSWORD
echo "  Password set for $ADMIN_USER"

# Resolve the admin user's primary group — don't assume user-private groups
ADMIN_GROUP="$(id -gn "$ADMIN_USER")"
[[ -n "$ADMIN_GROUP" ]] || { echo "  ERROR: Could not resolve primary group for $ADMIN_USER" >&2; exit 1; }

# Ensure default Debian sudo behavior: user password required
rm -f "/etc/sudoers.d/90-${ADMIN_USER}-nopasswd"

# ── Admin ~/.ssh scaffold ─────────────────────────────────────────────────────
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | awk -F: '{print $6}')"
[[ -n "$ADMIN_HOME" && -d "$ADMIN_HOME" ]] || { echo "  ERROR: Could not resolve home for $ADMIN_USER" >&2; exit 1; }

install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$ADMIN_HOME/.ssh"
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$ADMIN_HOME/.ssh/keys"
[[ -e "$ADMIN_HOME/.ssh/authorized_keys" ]] || touch "$ADMIN_HOME/.ssh/authorized_keys"
[[ -e "$ADMIN_HOME/.ssh/known_hosts" ]] || touch "$ADMIN_HOME/.ssh/known_hosts"
chown "$ADMIN_USER:$ADMIN_GROUP" "$ADMIN_HOME/.ssh/authorized_keys" "$ADMIN_HOME/.ssh/known_hosts"
chmod 0600 "$ADMIN_HOME/.ssh/authorized_keys" "$ADMIN_HOME/.ssh/known_hosts"

if [[ ! -f "$ADMIN_HOME/.ssh/config" ]]; then
  cat > "$ADMIN_HOME/.ssh/config" <<'EOF2'
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
EOF2
  chown "$ADMIN_USER:$ADMIN_GROUP" "$ADMIN_HOME/.ssh/config"
  chmod 0600 "$ADMIN_HOME/.ssh/config"
fi

chown -R "$ADMIN_USER:$ADMIN_GROUP" "$ADMIN_HOME/.ssh"
chmod 0700 "$ADMIN_HOME/.ssh" "$ADMIN_HOME/.ssh/keys"
chmod 0600 "$ADMIN_HOME/.ssh/authorized_keys" "$ADMIN_HOME/.ssh/config" "$ADMIN_HOME/.ssh/known_hosts"

# ── sshd hardening ────────────────────────────────────────────────────────────
mkdir -p /etc/ssh/sshd_config.d
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/[^[:space:]]+\.conf([[:space:]]|$)' /etc/ssh/sshd_config; then
  printf '
Include /etc/ssh/sshd_config.d/*.conf
' >> /etc/ssh/sshd_config
fi

SSHD_DROPIN="/etc/ssh/sshd_config.d/10-vault-hardening.conf"
cat > "$SSHD_DROPIN" <<EOF2
Port $SSH_PORT
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
UsePAM yes
PermitEmptyPasswords no
PermitUserEnvironment no
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
LoginGraceTime 30
AllowUsers $ADMIN_USER
AllowTcpForwarding $([ "$ALLOW_TCP_FORWARDING" -eq 1 ] && echo yes || echo no)
AllowAgentForwarding $([ "$ALLOW_AGENT_FORWARDING" -eq 1 ] && echo yes || echo no)
X11Forwarding $([ "$ALLOW_X11_FORWARDING" -eq 1 ] && echo yes || echo no)
PermitTunnel no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF2
[[ -n "$SSH_LISTEN_ADDRESS" ]] && printf 'ListenAddress %s
' "$SSH_LISTEN_ADDRESS" >> "$SSHD_DROPIN"

if ! sshd -t; then
  echo "  ERROR: sshd configuration test failed. Removing vault drop-in." >&2
  rm -f "$SSHD_DROPIN"
  exit 1
fi

systemctl enable ssh >/dev/null
systemctl restart ssh
echo "  SSH hardened for user: $ADMIN_USER"

# ── Root protection ───────────────────────────────────────────────────────────
if [[ "$LOCK_ROOT_PASSWORD" -eq 1 ]]; then
  passwd -l root >/dev/null
  echo "  Root password locked"
fi

# ── vault-key helper ──────────────────────────────────────────────────────────
cat > "$VAULT_HELPER_PATH" <<'EOF2'
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
      printf '  %-24s %s
' "$key_alias" "${d%/}/id_ed25519.pub"
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
    printf 'Private: %s
Public:  %s
' "$priv" "$pub"
    ;;
  export)
    key_alias="${2:-}"
    [[ -n "$key_alias" ]] || die "Usage: vault-key export <alias>"
    validate_alias "$key_alias"
    pub="${KEYS_DIR}/${key_alias}/id_ed25519.pub"
    [[ -f "$pub" ]] || die "No such key: ${key_alias}"
    printf 'Name: %s
' "$key_alias"
    printf 'Type: %s
' "$(awk '{print $1}' "$pub")"
    printf 'Suggested cloud label: %s-%s
' "$(hostname -s 2>/dev/null || echo vault)" "$key_alias"
    printf 'Public key:
'
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
EOF2
chmod 0755 "$VAULT_HELPER_PATH"

# ── MOTD hint ─────────────────────────────────────────────────────────────────
if [[ -d /etc/update-motd.d ]]; then
  # NOTE: unquoted heredoc — $ADMIN_USER is interpolated at install time.
  # Any other $var added below will also be interpolated now, not at runtime.
  cat > "$MOTD_HELPER" <<EOF2
#!/bin/sh
printf '\n'
printf '  Vault key helper:\n'
printf '    su - $ADMIN_USER\n'
printf '    vault-key help\n'
printf '    vault-key add cloud-example 203.0.113.10 debian\n'
printf '    vault-key export cloud-example\n'
printf '    vault-key list\n'
printf '\n'
printf '  Inbound SSH to this vault stays locked until you add a key to:\n'
printf '    /home/$ADMIN_USER/.ssh/authorized_keys\n'
printf '\n'
EOF2
  chmod 0755 "$MOTD_HELPER"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  Done."
echo "  Local admin user: $ADMIN_USER"
echo "  Sudo: standard Debian behavior (user password required)"
echo "  SSH: installed and hardened for $ADMIN_USER only"
echo "  Inbound SSH to this vault CT is locked until you add a public key to:"
echo "    /home/$ADMIN_USER/.ssh/authorized_keys"
echo "  Key helper: $VAULT_HELPER_PATH"
echo ""
echo "  Next steps:"
echo "    1) su - $ADMIN_USER"
echo "    2) Add an inbound login key to /home/$ADMIN_USER/.ssh/authorized_keys"
echo "    3) vault-key add cloud-example 203.0.113.10 debian"
echo "    4) vault-key export cloud-example"
echo ""
