---
name: lab-app-script
description: Write Bash deployment scripts that create and provision Proxmox VE LXC containers with applications, or batch-operate on existing containers. Use when the user asks to create, audit, refactor, or fix scripts that automate LXC container creation on Proxmox — including OS setup, application installation (Docker/Podman/native), systemd services, MOTD, hardening, and unattended upgrades. Also covers batch utility scripts like updaters. Trigger on mentions of LXC scripts, Proxmox deployment, container provisioning, deblxc, or any service deployment script for the homelab.
---

# Lab App Script

Write production-grade Bash scripts that create and fully provision Proxmox VE LXC containers with applications, or batch-operate on existing containers. Every provisioning script follows an identical skeleton so that any container in the lab is built, hardened, and documented the same way. Batch utility scripts follow their own pattern documented separately.

## Critical Rule

**ALWAYS extract patterns from the user's existing working scripts first.** Never invent new abstractions, helper functions, or "improvements" unless explicitly asked. The scripts are battle-tested — match their style exactly.
**NEVER** perform script edits without explicit user confirmation. Always describe the planned changes first and wait for approval before using any edit tools.

---

## Shell Header & Settings

Every script starts with:

```bash
#!/usr/bin/env bash
set -Eeo pipefail
```

- `set -E` — ERR traps inherited by functions/subshells.
- `set -e` — Exit on non-zero return.
- `set -o pipefail` — Pipe fails if any command fails.
- **Never** use `set -u` at the top level. Variables are validated manually.
- Inside `pct exec` blocks, `set -euo pipefail` **is** used (see §Executing Commands).
- **Line endings:** LF only (`\n`), never CRLF.

---

## Script Types & Families

### Type 1: Provisioning Scripts (Container Creators)

Create a new LXC and fully provision it. Two families:

**Native family** — app installed directly on Debian:
`deblxc.sh`, `samba.sh`, `unbound.sh`, `cryptpad.sh`, `docmost.sh`, `privatebin.sh`

**Podman family** — app runs in Podman containers:
`npm-podman.sh`, `matrix-podman.sh`, `docmost-podman.sh`

The families share the same skeleton but differ in:

| Aspect | Native | Podman |
|--------|--------|--------|
| LXC features | `nesting=1` | `nesting=1,keyctl=1,fuse=1` |
| Sysctl hardening | IPv4 + IPv6 disable (identical) | IPv4 + IPv6 disable (identical) |
| Reboot | Simple stop/start or `pct reboot` | `pct reboot` + stack container count verification |
| Stack service | None (native systemd units) | `appname-stack.service` (oneshot, podman-compose up/down) |
| Auto-update | App-specific timer (if any) | Timer pulls new images + restarts compose |

### Type 2: Batch Utility Scripts

Operate on multiple existing containers. Examples: `updatelxc.sh`. Argument parsing, container loops, different cleanup. See §Batch Utility Scripts.

---

# Provisioning Script Skeleton

Every provisioning script follows this phase order. Phases may be omitted if not applicable, but the order never changes.

```
 1. Config block                              16. Remove unnecessary services
 2. Custom configs manifest (comment)         17. Set timezone
 3. Config validation (if injectable values)  18. Application install
 4. Trap cleanup (ERR + INT/TERM)             19. Application configuration
 5. Preflight — root & commands               20. Verification
 6. Discover available resources              21. Secrets generation (if needed)
 7. Show defaults & confirm                   22. Persistent volumes (if needed)
 8. Download-on-cancel                        23. Config file generation
 9. Preflight — environment                   24. Config patching & validation
10. Root password                             25. Optional features
11. Application-specific prompts              26. Systemd services
12. Template discovery & download             27. Pull images / prepare app
13. Create LXC                                28. Start stack & health checks
14. Start & wait for IPv4                     29. Unattended upgrades
15. Auto-login (if no password)               30. Sysctl hardening
    OS update                                 31. Cleanup packages
    Configure locale                          32. MOTD (dynamic drop-ins)
                                              33. Proxmox UI description
                                              34. Protect container
                                              35. Summary
                                              36. Reboot & verify
```

---

## Section Comment Format

Every section uses em-dash banners padded to approximately column 80:

```bash
# ── Section name ──────────────────────────────────────────────────────────────
```

**Standard section names** (use these exactly):

| Phase | Section comment |
|-------|----------------|
| 1 | `# ── Config` |
| 2 | `# ── Custom configs created by this script` |
| 3 | `# ── Config validation` |
| 4 | `# ── Trap cleanup` |
| 5 | `# ── Preflight — root & commands` |
| 6 | `# ── Discover available resources` |
| 7 | `# ── Show defaults & confirm` |
| 9 | `# ── Preflight — environment` |
| 10 | `# ── Root password` |
| 12 | `# ── Template discovery & download` |
| 13 | `# ── Create LXC` |
| 14 | `# ── Start & wait for IPv4` |
| 15 | `# ── Auto-login (if no password)` |
|  | `# ── OS update` |
|  | `# ── Configure locale` |
| 16 | `# ── Remove unnecessary services` |
| 17 | `# ── Set timezone` |
| 29 | `# ── Unattended upgrades` |
| 30 | `# ── Sysctl hardening` |
| 31 | `# ── Cleanup packages` |
| 32 | `# ── MOTD (dynamic drop-ins)` |
| 33 | `# ── Proxmox UI description` |
| 34 | `# ── Protect container` |
| 35 | `# ── Summary` |
| 36 | `# ── Reboot` |

---

## Phase Details

### 1. Config Block

All tunables at the top under `# ── Config`. Grouped by purpose. Nothing hardcoded deeper.

```bash
# ── Config ────────────────────────────────────────────────────────────────────
CT_ID="$(pvesh get /cluster/nextid)"
HN="appname"
CPU=4
RAM=4096
DISK=8
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
CONTAINER_STORAGE="local-lvm"

# Application-specific
APP_PORT=8080
APP_TZ="Europe/Berlin"
TAGS="appname;lxc"

# Images (if containerized)
APP_IMAGE="docker.io/library/app:latest"
DEBIAN_VERSION=13

# Optional features
INSTALL_OPTIONAL_THING=0  # 1 = install, 0 = skip

# Behavior
CLEANUP_ON_FAIL=1  # 1 = destroy CT on error, 0 = keep for debugging
```

Rules: `CT_ID` auto-assigned. `DEBIAN_VERSION` numeric. `TAGS` semicolon-separated. Optional features use `0`/`1` flags. Post-install instructions as comments (samba pattern).

**Timezone variable:** All scripts use `APP_TZ`. This makes the Set timezone block verbatim-identical across all scripts.

### 2. Custom Configs Manifest

List every file the script creates inside the container. Mark conditional files.

```bash
# ── Custom configs created by this script ─────────────────────────────────────
#   /opt/appname/docker-compose.yml
#   /etc/update-motd.d/00-header
#   /etc/update-motd.d/10-sysinfo
#   /etc/update-motd.d/30-app
#   /etc/update-motd.d/35-optional           (if INSTALL_OPTIONAL=1)
#   /etc/update-motd.d/99-footer
#   /etc/systemd/system/container-getty@1.service.d/override.conf
#   /etc/apt/apt.conf.d/52unattended-<hostname>.conf
#   /etc/sysctl.d/99-hardening.conf
```

### 3. Config Validation (if needed)

When config values are used in `sed` substitutions, validate with regex **before** traps to prevent injection.

```bash
fail=""
[[ "$SMB_WORKGROUP"    =~ ^[A-Za-z0-9._-]+$ ]]     || fail="SMB_WORKGROUP"
[[ "$SMB_SERVER_NAME"  =~ ^[A-Za-z0-9._-]+$ ]]     || fail="SMB_SERVER_NAME"
[[ "$SMB_SHARE_PATH"   =~ ^/[A-Za-z0-9/_.-]+$ ]]   || fail="SMB_SHARE_PATH"
if [[ -n "$fail" ]]; then
  echo "  ERROR: Invalid characters in $fail — check the Config section." >&2
  exit 1
fi
```

### 4. Trap Cleanup

Two traps: `ERR` and `INT TERM`. Check `CLEANUP_ON_FAIL` and `CREATED` before destroying.

```bash
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
```

`trap - ERR` prevents recursive trapping. `|| true` on cleanup — must never fail. `CREATED` set to `1` only after `pct create`.

### 5. Preflight — Root & Commands

```bash
# ── Preflight — root & commands ───────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pvesh pveam pct pvesm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

[[ -n "$CT_ID" ]] || { echo "  ERROR: Could not obtain next CT ID." >&2; exit 1; }
```

### 6. Discover Available Resources

**Standard variable names** — always use the `AVAIL_` prefix:

```bash
# ── Discover available resources ──────────────────────────────────────────────
AVAIL_BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort | paste -sd', ' || echo "n/a")"
AVAIL_TMPL_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'vztmpl' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
AVAIL_CT_STORES="$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c "import sys,json; print(', '.join(sorted(s['storage'] for s in json.load(sys.stdin) if 'rootdir' in s.get('content',''))))" 2>/dev/null || echo "n/a")"
```

**Rules:**
- Variable names: `AVAIL_BRIDGES`, `AVAIL_TMPL_STORES`, `AVAIL_CT_STORES` — never the old `BRIDGES`, `TMPL_STORES`, `CT_STORES`.
- Bridge discovery must include `| sort` before `paste`.
- Display in banner as: `Bridge: $BRIDGE ($AVAIL_BRIDGES)`.

### 7. Show Defaults & Confirm

```bash
# ── Show defaults & confirm ───────────────────────────────────────────────────
cat <<EOF

  AppName LXC Creator — Configuration
  ────────────────────────────────────────
  CT ID:             $CT_ID
  Hostname:          $HN
  Bridge:            $BRIDGE ($AVAIL_BRIDGES)
  Template storage:  $TEMPLATE_STORAGE ($AVAIL_TMPL_STORES)
  Container storage: $CONTAINER_STORAGE ($AVAIL_CT_STORES)
  ...app-specific values...
  Cleanup on fail:   $CLEANUP_ON_FAIL
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF
```

**Conditional** for optional features: `$([ "$FLAG" -eq 1 ] && echo "yes" || echo "no")`

### 8. Download-on-Cancel

When the user declines the default configuration, download the script locally for editing. This pattern is **identical** across all scripts except for `SCRIPT_URL` and `SCRIPT_LOCAL`.

```bash
SCRIPT_URL="https://raw.githubusercontent.com/vdarkobar/scripts/main/appname.sh"
SCRIPT_LOCAL="/root/appname.sh"

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
```

**Rules:**
- `SCRIPT_URL` points to the raw GitHub URL matching the script's own filename.
- `SCRIPT_LOCAL` is always `/root/<scriptname>.sh`.
- `curl -fsSL` with error handling.
- `chmod +x` after download.
- Display edit/run instructions.
- `exit 0` on cancel.

### 9. Preflight — Environment

```bash
# ── Preflight — environment ───────────────────────────────────────────────────
pvesm status | awk -v s="$TEMPLATE_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Template storage not found: $TEMPLATE_STORAGE" >&2; exit 1; }
pvesm status | awk -v s="$CONTAINER_STORAGE" '$1==s{f=1} END{exit(!f)}' \
  || { echo "  ERROR: Container storage not found: $CONTAINER_STORAGE" >&2; exit 1; }
ip link show "$BRIDGE" >/dev/null 2>&1 \
  || { echo "  ERROR: Bridge not found: $BRIDGE" >&2; exit 1; }
```

### 10. Root Password

No spaces, min 5 chars, confirmation match. Blank = auto-login.

```bash
# ── Root password ─────────────────────────────────────────────────────────────
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
```

### 11. Application-Specific Prompts

**Username/password** (samba): nested loops, blank = skip, regex validation on username.
**Token with format check** (cloudflare): validate prefix (`^eyJ`), allow override with confirmation.

Patterns: blank = skip (optional) or blank = error (required). Validate format but allow override.

### 12. Template Discovery & Download

```bash
# ── Template discovery & download ─────────────────────────────────────────────
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
```

Try exact Debian version → fall back to any Debian → fail. Skip download if cached.

### 13. Create LXC

```bash
# ── Create LXC ────────────────────────────────────────────────────────────────
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
```

- Always `unprivileged 1`.
- **Native family:** `-features "nesting=1"`
- **Podman family:** `-features "nesting=1,keyctl=1,fuse=1"`
- Password conditional — only add if non-empty.

### 14. Start & Wait for IPv4

```bash
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
```

30s timeout. `sh -lc` (not bash). `scope global` excludes loopback.

### 15. Auto-login (if no password)

```bash
# ── Auto-login (if no password) ───────────────────────────────────────────────
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
```

### OS Update

```bash
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
```

Always `DEBIAN_FRONTEND=noninteractive`, `--force-confold`. Disable `systemd-networkd-wait-online`.

### Configure Locale

```bash
# ── Configure locale ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y locales
  sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
'
```

### 16. Remove Unnecessary Services

```bash
# ── Remove unnecessary services ───────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  systemctl disable --now ssh 2>/dev/null || true
  systemctl disable --now postfix 2>/dev/null || true
  apt-get purge -y openssh-server postfix 2>/dev/null || true
  apt-get -y autoremove
'
```

Disable before purge. `|| true` — services may not exist.

### 17. Set Timezone

```bash
# ── Set timezone ──────────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  ln -sf /usr/share/zoneinfo/${APP_TZ} /etc/localtime
  echo '${APP_TZ}' > /etc/timezone
"
```

### 18–20. Application Install, Configuration, Verification

**Podman-based:**
- Install: `podman podman-compose fuse-overlayfs curl ca-certificates iproute2 python3`
- Configure: storage driver (fuse-overlayfs), registries, log rotation
- Verify: `podman info`, `podman --version`, `podman-compose --version`

**Native (samba, unbound, cryptpad, docmost, privatebin):**
- Install from apt
- Write config, validate with app tools (`testparm -s`, `unbound-checkconf`)
- Start native service: `systemctl enable && systemctl restart`

### 21. Secrets Generation

```bash
DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 63 || true)"
[[ ${#DB_PASSWORD} -eq 63 ]] || { echo "  ERROR: Failed to generate secrets." >&2; exit 1; }
```

`/dev/urandom` + `tr -dc`. Validate length. `|| true` after `head` prevents pipefail.

### 22. Persistent Volumes

Create directories with correct UID/GID. Document UIDs with verification date.

```bash
# Verified UIDs: postgres:18-alpine=70, redis:8-alpine=999:1000, synapse=991 (2025-02)
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  mkdir -p /opt/appname/postgresdata /opt/appname/redis /opt/appname/synapse
  chown -R 70:70 /opt/appname/postgresdata
  chmod 700 /opt/appname/postgresdata
'
```

**⚠ PostgreSQL volume path note:** The official postgres image sets `PGDATA=/var/lib/postgresql/data`. When mapping volumes in compose, prefer mounting to `/var/lib/postgresql/data` (not `/var/lib/postgresql`). Mounting to the parent dir works because postgres creates `data/` inside it, but mounting directly to the `data` path avoids edge cases with non-empty directory detection on first init and is the officially recommended approach.

### 23. Config File Generation

**Pattern A — Placeholder substitution** (compose files with many variables):
```bash
# Write template with __PLACEHOLDERS__
pct exec "$CT_ID" -- bash -lc 'cat > /opt/appname/docker-compose.yml <<YAML
    image: __APP_IMAGE__
    environment:
      - DB_PASSWORD=__DB_PASSWORD__
YAML
'
# Substitute
pct exec "$CT_ID" -- sed -i \
  -e "s|__APP_IMAGE__|${APP_IMAGE}|g" \
  -e "s|__DB_PASSWORD__|${DB_PASSWORD}|g" \
  /opt/appname/docker-compose.yml
# Lock down
pct exec "$CT_ID" -- chmod 600 /opt/appname/docker-compose.yml
```

When config values come from user input, validate with regex first (§3).

**Pattern B — Direct heredoc** (simpler configs):
```bash
pct exec "$CT_ID" -- bash -lc "cat > /opt/appname/config.json <<EOF
{\"server\": \"https://${APP_DOMAIN}\"}
EOF"
```

### 24. Config Patching & Validation

Python for complex multi-line regex edits:
```bash
pct exec "$CT_ID" -- python3 - /path/to/config.yaml <<'PYEOF'
import sys, re
with open(sys.argv[1], 'r') as f: content = f.read()
content = re.sub(r'pattern', 'replacement', content)
with open(sys.argv[1], 'w') as f: f.write(content)
PYEOF
```

Validate with app-specific tools (preferred) or grep:
```bash
if pct exec "$CT_ID" -- testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
  echo "  Configuration validation passed"
else
  echo "  WARNING: Configuration validation had warnings (may still work)"
fi
```

### 25. Optional Features

Gated on config flags. Install → configure → enable → verify → MOTD drop-in → tag update.

```bash
if [[ "$INSTALL_CLOUDFLARED" -eq 1 && -n "$TUNNEL_TOKEN" ]]; then
  # Install from upstream repo, configure, enable, verify
  sleep 3
  if pct exec "$CT_ID" -- systemctl is-active --quiet cloudflared 2>/dev/null; then
    echo "  Cloudflared service is running"
  else
    echo "  WARNING: ..." >&2
  fi
fi
# Later, after MOTD section:
if [[ "$INSTALL_CLOUDFLARED" -eq 1 ]]; then
  # Add 35-cloudflared MOTD drop-in
  pct set "$CT_ID" --tags "${TAGS};cloudflared"
fi
```

### 26. Systemd Services

**Podman stack service:**
```ini
[Unit]
Description=AppName (Podman) stack
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/appname
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStopSec=60
[Install]
WantedBy=multi-user.target
```

**Auto-update timer** (biweekly): `OnCalendar=*-*-01 05:30:00` + `*-*-15 05:30:00`, `Persistent=true`, `RandomizedDelaySec=300`.

Native services use their own systemd units — no stack service or timer needed.

### 27–28. Pull & Start & Health Checks

**Podman:** pull → `systemctl enable --now` → poll container count → HTTP health check per endpoint.

```bash
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge $EXPECTED ]] && break; sleep 2
done
```

**Native:** `systemctl is-active --quiet servicename` + app-specific checks (`dig @127.0.0.1`, `testparm`).

**Diagnosis on failure:** `podman-compose logs --tail=80` for Podman, `journalctl -u service --no-pager -n 20` for native.

Health check results are **warnings, not errors** — service may still be initializing.

### 29. Unattended Upgrades

Create `52unattended-appname.conf` (never overwrite Debian defaults):

```bash
# ── Unattended upgrades ──────────────────────────────────────────────────────
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
```

Dynamic codename. Never auto-reboot. File named `52unattended-$(hostname).conf` — uses `$(hostname)` so the block is verbatim-identical across all scripts.

### 30. Sysctl Hardening

Identical across all 9 scripts — IPv4 hardening + IPv6 disable (all containers use `ip6=manual` at creation, so IPv6 is unused):

```bash
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
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null 2>&1 || true
'
```

### 31. Cleanup Packages

```bash
# ── Cleanup packages ──────────────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y man-db manpages 2>/dev/null || true
  apt-get -y autoremove
  apt-get -y clean
'
```

### 32. MOTD (Dynamic Drop-ins)

| File | Purpose | Present in |
|------|---------|-----------|
| `00-header` | App name + separator | All |
| `10-sysinfo` | Hostname, IP, uptime, disk | All (identical) |
| `30-app` | App-specific: stack, ports, commands | App scripts (not deblxc) |
| `35-*` | Conditional drop-ins (cloudflared) | When feature enabled |
| `99-footer` | Closing separator | All |

**Wrapper structure:**

```bash
# ── MOTD (dynamic drop-ins) ───────────────────────────────────────────────────
pct exec "$CT_ID" -- bash -lc "
  set -euo pipefail
  > /etc/motd
  chmod -x /etc/update-motd.d/* 2>/dev/null || true
  rm -f /etc/update-motd.d/*
  # ... write 00-header, 10-sysinfo, 30-app, 99-footer ...
  chmod +x /etc/update-motd.d/*
"
```

The outer `pct exec` block uses **double quotes** because `30-app` needs host-side variable expansion (e.g. `${APP_PORT}`). Individual heredocs use `<<'MOTD'` (single-quoted delimiter) so shell variables inside the MOTD scripts are not expanded at write-time.

**Standard 00-header:**

```bash
  cat > /etc/update-motd.d/00-header <<'MOTD'
#!/bin/sh
printf '\n  AppName\n'
printf '  ────────────────────────────────────\n'
MOTD
```

**Standard 10-sysinfo (identical across ALL scripts):**

```bash
  cat > /etc/update-motd.d/10-sysinfo <<'MOTD'
#!/bin/sh
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Hostname:  %s\n' \"\$(hostname)\"
printf '  IP:        %s\n' \"\${ip:-n/a}\"
printf '  Uptime:    %s\n' \"\$(uptime -p 2>/dev/null || uptime)\"
printf '  Disk:      %s\n' \"\$(df -h / | awk 'NR==2{printf \"%s/%s (%s used)\", \$3, \$2, \$5}')\"
MOTD
```

**Standard 99-footer:**

```bash
  cat > /etc/update-motd.d/99-footer <<'MOTD'
#!/bin/sh
printf '  ────────────────────────────────────\n\n'
MOTD
```

**30-app (Podman family):** container count via `podman ps`, compose commands, timer status, port URLs. Uses inline `\$(...)` calls, no intermediate variables.

```bash
  cat > /etc/update-motd.d/30-app <<'MOTD'
#!/bin/sh
running=\$(podman ps --format '{{.Names}}' 2>/dev/null | wc -l)
printf '  Stack:     /opt/appname (%s containers running)\n' \"\$running\"
printf '  Compose:   cd /opt/appname && podman-compose [up -d|down|logs|ps]\n'
printf '  Updates:   systemctl status appname-update.timer\n'
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '  Web UI:    http://%s:${APP_PORT}\n' \"\${ip:-n/a}\"
MOTD
```

**30-app (Native family):** `systemctl is-active` check, config paths, reload/restart commands, maintenance script commands. Uses inline calls, no intermediate variables.

```bash
  cat > /etc/update-motd.d/30-app <<'MOTD'
#!/bin/sh
service_active=\$(systemctl is-active appname 2>/dev/null || echo 'unknown')
printf '\n'
printf '  AppName:\n'
printf '    App dir:       /opt/appname\n'
printf '    Service:       %s\n' \"\$service_active\"
ip=\$(ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
printf '    Web UI:        http://%s:${APP_PORT}/\n' \"\$ip\"
printf '\n'
printf '  Maintenance:\n'
printf '    appname-maint.sh update\n'
printf '    appname-maint.sh backup\n'
MOTD
```

**MOTD escaping rules:**
- `#!/bin/sh` (POSIX) for all MOTD scripts.
- `printf` not `echo`.
- No leading indent inside the heredoc body (lines start at column 1).
- Escaping for the double-quoted outer `pct exec` block: `\$` for shell variables in MOTD, `\\\"` for literal quotes, `\n` for newlines.
- Never use `\\\\n` (double-escaped). The correct pattern is `\n` for newlines in printf.
- Inline `\$(command)` calls preferred over intermediate variables.
- Separator lines: exactly 36 box-drawing characters (`────────────────────────────────────`).

After MOTD, set TERM:
```bash
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  touch /root/.bashrc
  grep -q "^export TERM=" /root/.bashrc 2>/dev/null || echo "export TERM=xterm-256color" >> /root/.bashrc
'
```

### 33. Proxmox UI Description

**With web UI** (clickable links + details):
```bash
# ── Proxmox UI description ────────────────────────────────────────────────────
DESC="<a href='http://${CT_IP}:${PORT}/' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>App Web UI</a>
<details><summary>Details</summary>AppName on Debian ${DEBIAN_VERSION} LXC
Created by appname.sh</details>"
pct set "$CT_ID" --description "$DESC"
```

**Without web UI** (plain text): `"AppName (${CT_IP})\n<details>..."`

Conditional notes: `CF_NOTE=""; [[ "$FLAG" -eq 1 ]] && CF_NOTE=" + Feature"`

### 34. Protect Container

```bash
# ── Protect container ─────────────────────────────────────────────────────────
pct set "$CT_ID" --protection 1
```

### 35. Summary

**Compact one-liner** (most scripts):
```bash
echo "CT: $CT_ID | IP: ${CT_IP} | Admin: http://${CT_IP}:${PORT} | Login: $([ -n "$PASSWORD" ] && echo 'password set' || echo 'auto-login')"
```

**Extended block** (matrix — reverse proxy, admin commands, federation test URL).

Post-install commands in summary (samba: `pct exec ... smbpasswd -a`).

### 36. Reboot & Verify

**Podman stacks** — reboot + verify container count (90s timeout):
```bash
# ── Reboot ────────────────────────────────────────────────────────────────────
pct reboot "$CT_ID"
for i in $(seq 1 90); do
  RUNNING="$(pct exec "$CT_ID" -- sh -lc 'podman ps --format "{{.Names}}" 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  [[ "$RUNNING" -ge $EXPECTED ]] && break; sleep 2
done
[[ "$RUNNING" -ge $EXPECTED ]] && echo "  Stack came up after reboot" \
  || echo "  WARNING: Stack not fully up — check service" >&2
```

**Native services** — simple reboot, no stack verification.
**Base containers** (deblxc) — no reboot at all.

---

## Executing Commands Inside the Container

```bash
# Multi-line — bash heredoc
pct exec "$CT_ID" -- bash -lc '
  set -euo pipefail
  command1
  command2
'

# Simple single command
pct exec "$CT_ID" -- podman --version
```

**`set -euo pipefail` inside every multi-line `pct exec bash -lc` block.** This is the standard. (`-u` is safe inside because the environment is controlled.)

**Exceptions that do NOT need `set -euo pipefail`:**
- One-liner commands: `pct exec "$CT_ID" -- bash -lc 'cd /opt/app && podman-compose pull'`
- Pure file writes (heredoc → file): `pct exec "$CT_ID" -- bash -lc 'cat > /path/file <<EOF ... EOF'`
- Maintenance script writes: `pct exec "$CT_ID" -- bash -lc 'cat > /usr/local/bin/maint.sh <<'\''MAINT'\'' ... MAINT'`

These are effectively single operations where `set -euo pipefail` adds no value.

**Quote rules:**
- `bash -lc` for multi-line (login shell).
- `sh -lc` only for minimal checks (IP polling, container count).
- Double quotes for host variable expansion, single quotes to prevent it.

---

## Style Conventions

- All messages indented **2 spaces**: `echo "  Some message"`
- Errors to stderr: `echo "  ERROR: ..." >&2`
- Warnings to stderr: `echo "  WARNING: ..." >&2`
- Section banners: `# ── Name ──...──` (em-dashes to column 80)
- Polling: `for i in $(seq 1 N)` + post-loop validation
- Quoting: always `"$VAR"`, `"${VAR}"`, `"${ARRAY[@]}"`
- Defaults: `${VAR:-default}`
- Line endings: LF only (`\n`), never CRLF (`\r\n`)

---

## Known Gotchas

### PostgreSQL Volume Mapping

The official postgres image uses `PGDATA=/var/lib/postgresql/data`. When writing compose volumes:

- **Recommended:** `- /opt/app/postgresdata:/var/lib/postgresql/data:Z` (mount directly to PGDATA)
- **Also works:** `- /opt/app/postgresdata:/var/lib/postgresql:Z` (postgres creates `data/` inside)

The second form works but means actual data lives at `/opt/app/postgresdata/data/` on the host, which can be confusing for backups and inspection. Prefer the first form for new scripts.

### Podman in Unprivileged LXC

- Requires `fuse-overlayfs` as storage driver (kernel overlay not available).
- Requires LXC features: `nesting=1,keyctl=1,fuse=1`.
- Nginx in unprivileged Podman can't bind ports <1024 — use high ports (e.g. 8080) and custom nginx configs.

---

# Batch Utility Scripts

Scripts like `updatelxc.sh` that operate on multiple existing containers.

## Skeleton

```
 1. Config block (flags with defaults)
 2. Argument parsing (while/case)
 3. Preflight (root + commands)
 4. State variables for traps (CURRENT_CT, STARTED_HERE)
 5. Traps (ERR + INT/TERM — shutdown, not destroy)
 6. Show config & confirm (with --yes bypass)
 7. Result tracking (failed_list, reboot_list, etc.)
 8. Main loop (iterate containers)
 9. Summary (failures, warnings, reboots)
```

## Argument Parsing

```bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)           ASSUME_YES=1; shift ;;
    -n|--dry-run)       DRY_RUN=1; shift ;;
    -x|--exclude)       shift; EXCLUDE_IDS="${EXCLUDE_IDS} ${1:-}"; shift ;;
    -h|--help)          cat <<'EOF' ... EOF; exit 0 ;;
    *) echo "  ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done
```

Short + long forms. Defaults in config block. `--help` with heredoc. Unknown = exit 2.

## Batch Traps

Cleanup = **shutdown** (not destroy). Tracks `CURRENT_CT` + `STARTED_HERE`.

## Confirm with --yes Bypass

```bash
if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "  Continue with these settings? [y/N]: " response
  case "${response,,}" in y|yes) ;; *) echo "  Cancelled."; exit 0 ;; esac
fi
```

## Container Loop

```bash
while read -r CT_ID CT_STATUS _LOCK _NAME; do
  [[ -z "${CT_ID:-}" ]] && continue
  CURRENT_CT="$CT_ID"
  STARTED_HERE=0
  # Skip: excluded, locked, stopped, wrong ostype, template
  # Process: snapshot → start if needed → run commands → shutdown if started
done < <(pct list | awk 'NR>1 {print $1, $2, $3, $4}')
```

Filters: ostype (`pct config | awk '/^ostype:/'`), template (`grep '^template:\s*1'`), exclusion (`" $EXCLUDE_IDS " == *" $CT_ID "*`).

Track results: `failed_list+="$CT_ID (reason)\n"`. Use `printf "%b"` to display.

## Batch Summary

```bash
echo "  Done."
if [[ -n "$failed_list" ]]; then
  echo "  Failures:"; printf "%b" "$failed_list" | sed 's/^/  /'
  exit 1
fi
```

---

## Audit Checklist (Provisioning Scripts)

- [ ] `#!/usr/bin/env bash` + `set -Eeo pipefail`
- [ ] LF line endings only (no CRLF)
- [ ] Config block with all tunables at top
- [ ] Custom configs manifest comment
- [ ] Config validation with regex (if sed-interpolated values)
- [ ] ERR + INT/TERM traps with CLEANUP_ON_FAIL + CREATED
- [ ] Root, command, CT_ID checks
- [ ] Resource discovery with `AVAIL_` prefix vars and `sort` on bridges
- [ ] Show defaults + y/N confirm
- [ ] Download-on-cancel with correct SCRIPT_URL and SCRIPT_LOCAL
- [ ] Storage + bridge validation
- [ ] Password prompt with validation
- [ ] App-specific prompts (if needed)
- [ ] Template discovery with fallback + cache skip
- [ ] PCT_OPTIONS with correct features for family (native vs Podman) + CREATED=1
- [ ] IPv4 wait loop (30s)
- [ ] Auto-login if no password
- [ ] OS update (DEBIAN_FRONTEND, --force-confold, disable wait-online)
- [ ] Configure locale (en_US.UTF-8)
- [ ] Remove ssh + postfix
- [ ] Set timezone
- [ ] App install + config + verify
- [ ] Secrets validated after generation
- [ ] Volumes with documented UIDs + correct mount paths
- [ ] Config files chmod 600 for sensitive
- [ ] Validation with app-specific tools
- [ ] Systemd services (stack + timer for Podman, native for apt)
- [ ] Health checks: warnings not errors, log dump on failure
- [ ] Unattended upgrades (52-conf with `$(hostname)`, dynamic codename, no auto-reboot)
- [ ] Sysctl hardening (IPv4 + IPv6 disable, identical across all scripts)
- [ ] Cleanup packages (man-db, manpages)
- [ ] MOTD drop-ins (POSIX sh, printf, no indent, inline style, `\n` escaping, TERM in .bashrc)
- [ ] Optional feature MOTD + tag updates
- [ ] Proxmox description (HTML links or plain + details)
- [ ] Protect container enabled
- [ ] Summary with connection info + admin commands
- [ ] Reboot + verify (Podman), simple reboot (native), or none (base)
- [ ] `set -euo pipefail` inside all multi-line pct exec bash blocks
- [ ] Standard section comment names (see §Section Comment Format)
