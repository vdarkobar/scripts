PROVISIONING SCRIPT FLOW
═════════════════════════

■ = verbatim-identical across all 9 scripts
◧ = verbatim structure, only named values differ
□ = app-specific (unique per script)

│
├─■ #!/usr/bin/env bash
├─■ set -Eeo pipefail
│
├─□ # ── Config ───────────────────────────
│   │  CT_ID, HN, CPU, RAM, DISK, BRIDGE,
│   │  TEMPLATE_STORAGE, CONTAINER_STORAGE,
│   │  APP_PORT, APP_TZ, TAGS, images, flags
│   │
│   ├─ native:  -features "nesting=1"
│   └─ podman:  -features "nesting=1,keyctl=1,fuse=1"
│
├─□ # ── Custom configs created by this script
│     (comment listing all files created)
│
├─□ # ── Config validation ────────────────
│     (only scripts with sed-interpolated values)
│
├─■ # ── Trap cleanup ─────────────────────
│   │  trap ERR  → report + conditional destroy
│   └─ trap INT TERM → same
│
├─■ # ── Preflight — root & commands ──────
│     id -u, pvesh/pveam/pct/pvesm, CT_ID
│
├─■ # ── Discover available resources ─────
│     AVAIL_BRIDGES  (ip -o link | sort)
│     AVAIL_TMPL_STORES  (pvesh JSON)
│     AVAIL_CT_STORES    (pvesh JSON)
│
├─◧ # ── Show defaults & confirm ──────────
│   │  cat <<EOF ... EOF
│   │  (structure identical, values differ)
│   │
│   ├─◧ SCRIPT_URL=".../<scriptname>.sh"
│   │   SCRIPT_LOCAL="/root/<scriptname>.sh"
│   │
│   ├─■ read -r -p "Continue? [y/N]"
│   │   case y/Y → continue
│   │
│   └─■ case * → download-on-cancel
│       │  curl -fsSL "$SCRIPT_URL"
│       │  chmod +x, echo edit/run
│       └─ exit 0
│
├─■ # ── Preflight — environment ──────────
│     pvesm storage checks, bridge check
│
├─■ # ── Root password ────────────────────
│     while loop, spaces/length/verify
│     blank = auto-login warning
│
├─□ # ── Application-specific prompts ─────
│     (samba user, cloudflare token, etc.)
│
├─■ # ── Template discovery & download ────
│     pveam update, DEBIAN_VERSION check,
│     version match → fallback → fail,
│     cache skip
│
├─◧ # ── Create LXC ──────────────────────
│   │  PCT_OPTIONS array (structure same)
│   │
│   ├─ native:  features "nesting=1"
│   ├─ podman:  features "nesting=1,keyctl=1,fuse=1"
│   └─■ pct create + CREATED=1
│
├─■ # ── Start & wait for IPv4 ────────────
│     pct start, 30s polling loop
│
├─■ # ── Auto-login (if no password) ──────
│     getty override, daemon-reload
│
├─■ # ── OS update ────────────────────────
│     DEBIAN_FRONTEND, disable wait-online,
│     dist-upgrade, autoremove, clean
│
├─■ # ── Configure locale ─────────────────
│     locales, en_US.UTF-8, locale-gen
│
├─■ # ── Remove unnecessary services ──────
│     disable+purge ssh, postfix
│
├─■ # ── Set timezone ─────────────────────
│     ln -sf .../APP_TZ, echo > timezone
│
│ ┌─────────────────────────────────────────┐
│ │  APP-SPECIFIC MIDDLE                    │
│ │  (phases 18–28 — unique per script)     │
│ │                                         │
│ │  □ Application install                  │
│ │  □ Application configuration            │
│ │  □ Verification                         │
│ │  □ Secrets generation                   │
│ │  □ Persistent volumes                   │
│ │  □ Config file generation               │
│ │  □ Config patching & validation         │
│ │  □ Optional features                    │
│ │  □ Systemd services                     │
│ │  □ Pull images / prepare app            │
│ │  □ Start stack & health checks          │
│ └─────────────────────────────────────────┘
│
├─■ # ── Unattended upgrades ──────────────
│     52unattended-$(hostname).conf
│
├─■ # ── Sysctl hardening ─────────────────
│     10 IPv4 lines + 3 IPv6 disable
│
├─■ # ── Cleanup packages ─────────────────
│     purge man-db manpages, autoremove
│
├── # ── MOTD (dynamic drop-ins) ──────────
│   │
│   ├─■ clear existing + set -euo pipefail
│   │
│   ├─◧ 00-header
│   │   printf '\n  <AppName>\n'
│   │   printf '  ────────────────────\n'
│   │
│   ├─■ 10-sysinfo
│   │   ip, hostname, uptime, disk
│   │
│   ├─□ 30-app
│   │   (completely unique per script)
│   │
│   ├─□ 35-* conditional drop-ins
│   │
│   ├─■ 99-footer
│   │   printf '  ────────────────────\n\n'
│   │
│   └─■ chmod +x + TERM in .bashrc
│
├─□ # ── Proxmox UI description ───────────
│     (HTML links + details, unique per app)
│
├─■ # ── Protect container ────────────────
│     pct set --protection 1
│
├─□ # ── Summary ──────────────────────────
│     (connection info, unique per app)
│
└─◧ # ── Reboot ───────────────────────────
    │
    ├─ deblxc:  (none)
    ├─ native:  pct stop + sleep + pct start
    └─ podman:  pct reboot + 90s container
               count verification loop (■)


TALLY
─────
■  verbatim:    21 blocks
◧  structural:   3 blocks (banner, LXC create,
                   reboot)
□  unique:       8 blocks (config, manifest,
                   validation, prompts, middle,
                   MOTD 30-app, description,
                   summary)
