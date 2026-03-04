#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
# Edit the values below to change defaults, then re-run the script.

ASSUME_YES=0          # -y / --yes              → Set to 1 to skip confirmation
SKIP_STOPPED=0        # -s / --skip-stopped     → Set to 1 to ignore stopped containers
START_STOPPED=1       # --no-start              → Set to 0 to never start stopped containers
DRY_RUN=0             # -n / --dry-run          → Set to 1 to only print actions
EXCLUDE_IDS=""        # -x / --exclude          → Space-separated CT IDs to skip
TAKE_SNAPSHOT=1       # --no-snapshot           → Set to 0 to disable snapshots
REQUIRE_SNAPSHOT=0    # --require-snapshot      → Set to 1 to treat snapshot failure as error
SNAPSHOT_PREFIX="preupd"
WAIT_SECS_AFTER_START=30
IGNORE_LOCKS=1        # --ignore-locks          → 1 = ignore locks (default), 0 = skip locked
CLEANUP_ON_FAIL=1     # --no-cleanup            → Set to 0 to keep started CTs on error

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)           ASSUME_YES=1; shift ;;
    -s|--skip-stopped)  SKIP_STOPPED=1; shift ;;
    --no-start)         START_STOPPED=0; shift ;;
    -n|--dry-run)       DRY_RUN=1; shift ;;
    -x|--exclude)
      shift
      EXCLUDE_IDS="${EXCLUDE_IDS} ${1:-}"
      shift
      ;;
    --no-snapshot)      TAKE_SNAPSHOT=0; shift ;;
    --require-snapshot) REQUIRE_SNAPSHOT=1; shift ;;
    --ignore-locks)     IGNORE_LOCKS=1; shift ;;
    --no-cleanup)       CLEANUP_ON_FAIL=0; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: lxc-update-debian.sh [options]

Options:
  -y, --yes              Skip confirmation prompt
  -s, --skip-stopped     Skip stopped containers
  --no-start             Never start stopped containers
  -n, --dry-run          Only show what would be done
  -x, --exclude IDs      CT IDs to skip (can be used multiple times)
  --no-snapshot          Disable snapshots
  --require-snapshot     Snapshot failure = treat as error
  --ignore-locks         Ignore locked containers (default)
  --no-cleanup           Keep started CTs on error (for debugging)
EOF
      exit 0
      ;;
    *) echo "  ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pct awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# ── State for traps ───────────────────────────────────────────────────────────
CURRENT_CT=""
STARTED_HERE=0

# ── Traps ─────────────────────────────────────────────────────────────────────
trap 'trap - ERR; rc=$?;
  echo "  ERROR: failed (rc=$rc) near line ${BASH_LINENO[0]:-?}" >&2
  echo "  Command: $BASH_COMMAND" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && -n "${CURRENT_CT:-}" && "${STARTED_HERE:-0}" -eq 1 ]]; then
    echo "  Cleanup: shutting down CT ${CURRENT_CT} ..." >&2
    pct shutdown "${CURRENT_CT}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' ERR

trap 'rc=$?;
  echo "  Interrupted (rc=$rc)" >&2
  if [[ "${CLEANUP_ON_FAIL:-0}" -eq 1 && -n "${CURRENT_CT:-}" && "${STARTED_HERE:-0}" -eq 1 ]]; then
    echo "  Cleanup: shutting down CT ${CURRENT_CT} ..." >&2
    pct shutdown "${CURRENT_CT}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
' INT TERM

# ── Show config & confirm ─────────────────────────────────────────────────────
cat <<EOF

  Debian LXC Updater — Configuration
  ────────────────────────────────────────
  Assume yes:       $([[ $ASSUME_YES -eq 1 ]] && echo Yes || echo No)
  Skip stopped:     $([[ $SKIP_STOPPED -eq 1 ]] && echo Yes || echo No)
  Start stopped:    $([[ $START_STOPPED -eq 1 ]] && echo Yes || echo No)
  Dry run:          $([[ $DRY_RUN -eq 1 ]] && echo Yes || echo No)
  Exclude IDs:      ${EXCLUDE_IDS:-<none>}
  Take snapshot:    $([[ $TAKE_SNAPSHOT -eq 1 ]] && echo Yes || echo No)
  Require snapshot: $([[ $REQUIRE_SNAPSHOT -eq 1 ]] && echo Yes || echo No)
  Ignore locks:     $([[ $IGNORE_LOCKS -eq 1 ]] && echo Yes || echo No)
  Snapshot prefix:  $SNAPSHOT_PREFIX
  Wait after start: ${WAIT_SECS_AFTER_START}s
  Cleanup on fail:  $([[ $CLEANUP_ON_FAIL -eq 1 ]] && echo Yes || echo No)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF

if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "  Continue with these settings? [y/N]: " response
  case "$response" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "  Cancelled."; exit 0 ;;
  esac
fi
echo ""

# ── Exclusions & result tracking ──────────────────────────────────────────────
excluded=" $EXCLUDE_IDS "
reboot_list=""
failed_list=""
snapshot_failed_list=""

# ── Main loop ─────────────────────────────────────────────────────────────────
while read -r CT_ID CT_STATUS _LOCK _NAME; do
  [[ -z "${CT_ID:-}" ]] && continue
  CURRENT_CT="$CT_ID"
  STARTED_HERE=0

  if [[ "$excluded" == *" $CT_ID "* ]]; then
    echo "  Skip $CT_ID (excluded)"
    continue
  fi

  # ── Lock handling ─────────────────────────────────────────────────────────
  if [[ $IGNORE_LOCKS -eq 0 ]]; then
    if [[ -n "${_LOCK:-}" && "${_LOCK:-}" != "-" ]]; then
      echo "  Skip $CT_ID (locked: ${_LOCK:-})"
      continue
    fi
  fi

  if [[ $SKIP_STOPPED -eq 1 && "${CT_STATUS:-}" == "stopped" ]]; then
    echo "  Skip $CT_ID (stopped)"
    continue
  fi

  template=0
  pct config "$CT_ID" 2>/dev/null | grep -qE '^template:\s*1\s*$' && template=1
  os="$(pct config "$CT_ID" 2>/dev/null | awk -F': ' '/^ostype:/ {print $2; exit}')"
  [[ -z "${os:-}" ]] && os="unknown"

  if [[ "$os" != "debian" ]]; then
    echo "  Skip $CT_ID (ostype=$os)"
    continue
  fi
  if [[ $template -eq 1 ]]; then
    echo "  Skip $CT_ID (template)"
    continue
  fi

  # ── Process container ──────────────────────────────────────────────────────
  echo ""

  if [[ $TAKE_SNAPSHOT -eq 1 ]]; then
    snap_name="${SNAPSHOT_PREFIX}-${CT_ID}-$(date '+%Y%m%d-%H%M%S')"
    echo "  Snapshot $CT_ID → $snap_name"
    if [[ $DRY_RUN -eq 0 ]]; then
      if ! pct snapshot "$CT_ID" "$snap_name" --description "auto pre-update $(date -Is)"; then
        echo "  WARNING: snapshot failed for $CT_ID" >&2
        snapshot_failed_list+="$CT_ID ($snap_name)\n"
        if [[ $REQUIRE_SNAPSHOT -eq 1 ]]; then
          failed_list+="$CT_ID (snapshot failed)\n"
          continue
        fi
      fi
    fi
  fi

  # ── Start stopped container ──────────────────────────────────────────────
  if [[ "${CT_STATUS:-}" == "stopped" ]]; then
    if [[ $START_STOPPED -eq 0 ]]; then
      echo "  Skip $CT_ID (stopped; --no-start)"
      continue
    fi
    echo "  Start $CT_ID"
    if [[ $DRY_RUN -eq 0 ]]; then
      if ! pct start "$CT_ID"; then
        echo "  ERROR: failed to start $CT_ID" >&2
        failed_list+="$CT_ID (start failed)\n"
        continue
      fi
      STARTED_HERE=1
      ready=0
      for ((i=1; i<=WAIT_SECS_AFTER_START; i++)); do
        if pct exec "$CT_ID" -- true >/dev/null 2>&1; then
          ready=1
          break
        fi
        sleep 1
      done
      if [[ $ready -eq 0 ]]; then
        echo "  ERROR: CT $CT_ID did not become ready in time" >&2
        failed_list+="$CT_ID (not ready after start)\n"
        continue
      fi
    fi
  fi

  # ── Resolve hostname ─────────────────────────────────────────────────────
  ct_name="?"
  if [[ $DRY_RUN -eq 0 ]] || [[ "${CT_STATUS:-}" != "stopped" ]]; then
    ct_name="$(pct exec "$CT_ID" -- hostname 2>/dev/null || echo "?")"
  else
    ct_name="(dry-run)"
  fi

  echo "  Update $CT_ID ($ct_name)"

  # ── Run update ───────────────────────────────────────────────────────────
  if [[ $DRY_RUN -eq 0 ]]; then
    if ! pct exec "$CT_ID" -- bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      export LANG=C.UTF-8
      export LC_ALL=C.UTF-8
      apt-get update -qq
      apt-get -o Dpkg::Options::="--force-confold" -y dist-upgrade
      apt-get -y autoremove --purge
      apt-get -y clean
      rm -rf /usr/lib/python3.*/EXTERNALLY-MANAGED || true
    '; then
      echo "  ERROR: update failed for $CT_ID" >&2
      failed_list+="$CT_ID (update failed)\n"
    fi
  fi

  # ── Check reboot required ────────────────────────────────────────────────
  if [[ $DRY_RUN -eq 0 ]]; then
    if pct exec "$CT_ID" -- bash -lc 'test -e /var/run/reboot-required || test -s /var/run/reboot-required.pkgs' 2>/dev/null; then
      reboot_list+="$CT_ID ($ct_name)\n"
    fi
  fi

  # ── Shutdown if we started it ────────────────────────────────────────────
  if [[ $STARTED_HERE -eq 1 ]]; then
    echo "  Shutdown $CT_ID"
    if [[ $DRY_RUN -eq 0 ]]; then
      pct shutdown "$CT_ID" >/dev/null 2>&1 || true
    fi
  fi

done < <(pct list | awk 'NR>1 {print $1, $2, $3, $4}')

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  Done."

if [[ -n "$snapshot_failed_list" ]]; then
  echo ""
  echo "  Snapshot failures:"
  printf "  %b" "$snapshot_failed_list" | sed 's/^/  /'
fi

if [[ -n "$reboot_list" ]]; then
  echo ""
  echo "  Containers requiring reboot:"
  printf "%b" "$reboot_list" | sed 's/^/  /'
fi

if [[ -n "$failed_list" ]]; then
  echo ""
  echo "  Failures:"
  printf "%b" "$failed_list" | sed 's/^/  /'
  exit 1
fi
echo ""
