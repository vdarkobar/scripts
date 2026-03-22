#!/usr/bin/env bash
set -Eeuo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SKIP_STOPPED=0             # -s / --skip-stopped     → 1 = ignore stopped containers
START_STOPPED=1            # --no-start              → 0 = never start stopped containers
DRY_RUN=0                  # -n / --dry-run          → 1 = only print actions
EXCLUDE_IDS=""             # -x / --exclude          → repeatable; numeric CT IDs
TAKE_SNAPSHOT=1            # --no-snapshot           → 0 = disable snapshots
SNAPSHOT_PREFIX="preupd"
WAIT_SECS_AFTER_START=30
IGNORE_LOCKS=1             # --respect-locks         → 0 = skip locked containers
CLEANUP_ON_FAIL=1          # --no-cleanup            → 0 = keep started CTs on error/interruption

# ── Parse args ────────────────────────────────────────────────────────────────
declare -A EXCLUDED=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--skip-stopped)
      SKIP_STOPPED=1
      shift
      ;;
    --no-start)
      START_STOPPED=0
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -x|--exclude)
      shift
      [[ $# -gt 0 ]] || { echo "  ERROR: --exclude requires at least one CT ID" >&2; exit 2; }
      raw_exclude="${1//,/ }"
      for ex_id in $raw_exclude; do
        [[ "$ex_id" =~ ^[0-9]+$ ]] || { echo "  ERROR: --exclude requires numeric CT IDs (got: $ex_id)" >&2; exit 2; }
        EXCLUDED["$ex_id"]=1
        EXCLUDE_IDS="${EXCLUDE_IDS} $ex_id"
      done
      shift
      ;;
    --no-snapshot)
      TAKE_SNAPSHOT=0
      shift
      ;;
    --respect-locks)
      IGNORE_LOCKS=0
      shift
      ;;
    --no-cleanup)
      CLEANUP_ON_FAIL=0
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: lxc-update.sh [options]

Options:
  -s, --skip-stopped     Skip stopped containers
  --no-start             Never start stopped containers
  -n, --dry-run          Only show what would be done
  -x, --exclude IDS      CT IDs to skip (repeatable; comma-separated allowed)
  --no-snapshot          Disable snapshots
  --respect-locks        Skip containers that are locked (default: ignore locks)
  --no-cleanup           Keep started CTs on error/interruption
  -h, --help             Show this help
EOF
      exit 0
      ;;
    *)
      echo "  ERROR: Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# ── Validate config ───────────────────────────────────────────────────────────
for bool_var in SKIP_STOPPED START_STOPPED DRY_RUN TAKE_SNAPSHOT IGNORE_LOCKS CLEANUP_ON_FAIL; do
  bool_val="${!bool_var}"
  [[ "$bool_val" =~ ^[01]$ ]] || { echo "  ERROR: $bool_var must be 0 or 1 (got: $bool_val)" >&2; exit 1; }
done

[[ "$WAIT_SECS_AFTER_START" =~ ^[0-9]+$ ]] || { echo "  ERROR: WAIT_SECS_AFTER_START must be a non-negative integer" >&2; exit 1; }
[[ -n "$SNAPSHOT_PREFIX" ]] || { echo "  ERROR: SNAPSHOT_PREFIX must not be empty" >&2; exit 1; }
[[ "$SNAPSHOT_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "  ERROR: SNAPSHOT_PREFIX contains invalid characters" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "  ERROR: Run as root on the Proxmox host." >&2; exit 1; }

for cmd in pct awk sed grep bash; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "  ERROR: Missing required command: $cmd" >&2; exit 1; }
done

# ── State / traps ─────────────────────────────────────────────────────────────
CURRENT_CT=""
STARTED_HERE=0

declare -a reboot_list=()
declare -a failed_list=()
declare -a snapshot_failed_list=()
declare -a bind_mount_skip_list=()
declare -a skipped_by_user_list=()
declare -a skipped_by_script_list=()

trap 'rc=$?;
  trap - ERR
  echo "  ERROR: failed (rc=$rc) near line ${BASH_LINENO[0]:-?}" >&2
  echo "  Command: ${BASH_COMMAND:-?}" >&2
  if [[ "${DRY_RUN:-0}" -eq 0 && "${CLEANUP_ON_FAIL:-0}" -eq 1 && -n "${CURRENT_CT:-}" && "${STARTED_HERE:-0}" -eq 1 ]]; then
    echo "  Cleanup: shutting down CT ${CURRENT_CT} ..." >&2
    pct shutdown "${CURRENT_CT}" >/dev/null 2>&1 || true
    STARTED_HERE=0
  fi
  exit "$rc"
' ERR

trap 'rc=$?;
  trap - INT TERM
  echo "  Interrupted (rc=$rc)" >&2
  if [[ "${DRY_RUN:-0}" -eq 0 && "${CLEANUP_ON_FAIL:-0}" -eq 1 && -n "${CURRENT_CT:-}" && "${STARTED_HERE:-0}" -eq 1 ]]; then
    echo "  Cleanup: shutting down CT ${CURRENT_CT} ..." >&2
    pct shutdown "${CURRENT_CT}" >/dev/null 2>&1 || true
    STARTED_HERE=0
  fi
  exit "$rc"
' INT TERM

# ── Show config ───────────────────────────────────────────────────────────────
cat <<EOF

  Debian LXC Updater — Configuration
  ────────────────────────────────────────
  Skip stopped:     $([[ "$SKIP_STOPPED" -eq 1 ]] && echo Yes || echo No)
  Start stopped:    $([[ "$START_STOPPED" -eq 1 ]] && echo Yes || echo No)
  Dry run:          $([[ "$DRY_RUN" -eq 1 ]] && echo Yes || echo No)
  Exclude IDs:      ${EXCLUDE_IDS:-<none>}
  Take snapshot:    $([[ "$TAKE_SNAPSHOT" -eq 1 ]] && echo Yes || echo No)
  Lock handling:    $([[ "$IGNORE_LOCKS" -eq 1 ]] && echo "Ignore locks" || echo "Skip locked")
  Snapshot prefix:  $SNAPSHOT_PREFIX
  Wait after start: ${WAIT_SECS_AFTER_START}s
  Cleanup on fail:  $([[ "$CLEANUP_ON_FAIL" -eq 1 ]] && echo Yes || echo No)
  ────────────────────────────────────────
  To change defaults, press Enter and
  edit the Config section at the top of
  this script, then re-run.

EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  Dry run mode: no changes will be made."
fi

if [[ ! -r /dev/tty ]]; then
  echo "  ERROR: no interactive tty available for confirmation." >&2
  exit 1
fi

printf "  Continue with these settings? [y/N]: " > /dev/tty
read -r response < /dev/tty
case "$response" in
  [yY]|[yY][eE][sS]) ;;
  *) echo "  Cancelled."; exit 0 ;;
esac

echo ""

# ── Main loop ─────────────────────────────────────────────────────────────────
while read -r CT_ID CT_STATUS; do
  [[ -z "${CT_ID:-}" ]] && continue

  CURRENT_CT="$CT_ID"
  STARTED_HERE=0

  if [[ -n "${EXCLUDED[$CT_ID]:-}" ]]; then
    echo "  Skip $CT_ID (excluded)"
    skipped_by_script_list+=("$CT_ID (excluded)")
    continue
  fi

  if ! cfg="$(pct config "$CT_ID" 2>/dev/null)"; then
    echo "  WARNING: unable to read config for CT $CT_ID — skipping" >&2
    failed_list+=("$CT_ID (unable to read container config)")
    skipped_by_script_list+=("$CT_ID (unable to read container config)")
    continue
  fi

  lock="$(awk -F': ' '$1 == "lock" {print $2; exit}' <<<"$cfg")"
  os="$(awk -F': ' '$1 == "ostype" {print $2; exit}' <<<"$cfg")"
  ct_name="$(awk -F': ' '$1 == "hostname" {print $2; exit}' <<<"$cfg")"

  [[ -n "$ct_name" ]] || ct_name="ct-$CT_ID"
  [[ -n "$os" ]] || os="unknown"

  if [[ "$IGNORE_LOCKS" -eq 0 && -n "$lock" ]]; then
    echo "  Skip $CT_ID ($ct_name) (locked: $lock)"
    skipped_by_script_list+=("$CT_ID ($ct_name) (locked: $lock)")
    continue
  fi

  if [[ "$SKIP_STOPPED" -eq 1 && "$CT_STATUS" == "stopped" ]]; then
    echo "  Skip $CT_ID ($ct_name) (stopped)"
    skipped_by_script_list+=("$CT_ID ($ct_name) (stopped)")
    continue
  fi

  if [[ "$os" != "debian" ]]; then
    echo "  Skip $CT_ID ($ct_name) (ostype=$os)"
    skipped_by_script_list+=("$CT_ID ($ct_name) (ostype=$os)")
    continue
  fi

  if grep -qE '^template:\s*1\s*$' <<<"$cfg"; then
    echo "  Skip $CT_ID ($ct_name) (template)"
    skipped_by_script_list+=("$CT_ID ($ct_name) (template)")
    continue
  fi

  echo ""

  if [[ "$TAKE_SNAPSHOT" -eq 1 ]]; then
    if grep -qE '^mp[0-9]+:\s*/' <<<"$cfg"; then
      echo "  WARNING: CT $CT_ID ($ct_name) has host bind mount(s) — snapshot cannot be taken" >&2
      bind_mount_skip_list+=("$CT_ID ($ct_name)")

      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  Would ask: continue updating $CT_ID ($ct_name) without snapshot? [y/N]"
      else
        printf "  Continue updating %s (%s) without snapshot? [y/N]: " "$CT_ID" "$ct_name" > /dev/tty
        read -r response < /dev/tty
        case "$response" in
          [yY]|[yY][eE][sS]) ;;
          *)
            echo "  Skip $CT_ID ($ct_name) (user chose not to continue without snapshot)"
            skipped_by_user_list+=("$CT_ID ($ct_name) (declined update without snapshot)")
            continue
            ;;
        esac
      fi
    else
      snap_name="${SNAPSHOT_PREFIX}-${CT_ID}-$(date '+%Y%m%d-%H%M%S')"
      echo "  Snapshot $CT_ID ($ct_name) → $snap_name"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        snap_out=""
        if ! snap_out="$(pct snapshot "$CT_ID" "$snap_name" --description "auto pre-update $(date -Is)" 2>&1)"; then
          [[ -n "$snap_out" ]] && printf '%s\n' "$snap_out" >&2
          echo "  WARNING: snapshot failed for $CT_ID ($ct_name)" >&2
          snapshot_failed_list+=("$CT_ID ($ct_name) → $snap_name")
          failed_list+=("$CT_ID ($ct_name): snapshot failed")
          continue
        elif [[ -n "$snap_out" ]]; then
          cleaned_snap_out="$(printf '%s\n' "$snap_out" | sed '/^failed to open .*\/overlay\/.*\/merged: Permission denied$/d;/^[[:space:]]*$/d')"
          if [[ -z "$cleaned_snap_out" ]]; then
            echo "  WARNING: snapshot completed with nested-container overlay warnings in CT $CT_ID ($ct_name)" >&2
          else
            printf '%s\n' "$snap_out" >&2
          fi
        fi
      fi
    fi
  fi

  if [[ "$CT_STATUS" == "stopped" ]]; then
    if [[ "$START_STOPPED" -eq 0 ]]; then
      echo "  Skip $CT_ID ($ct_name) (stopped; --no-start)"
      skipped_by_script_list+=("$CT_ID ($ct_name) (stopped; --no-start)")
      continue
    fi

    echo "  Start $CT_ID ($ct_name)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      if ! pct start "$CT_ID" >/dev/null; then
        echo "  ERROR: failed to start $CT_ID ($ct_name)" >&2
        failed_list+=("$CT_ID ($ct_name): start failed")
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

      if [[ "$ready" -eq 0 ]]; then
        echo "  ERROR: CT $CT_ID ($ct_name) did not become ready in time" >&2
        failed_list+=("$CT_ID ($ct_name): not ready after start")
        if [[ "$CLEANUP_ON_FAIL" -eq 1 && "$STARTED_HERE" -eq 1 ]]; then
          echo "  Cleanup: shutting down CT $CT_ID ..." >&2
          pct shutdown "$CT_ID" >/dev/null 2>&1 || true
          STARTED_HERE=0
        fi
        continue
      fi
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  Would update $CT_ID ($ct_name)"
  else
    echo "  Update $CT_ID ($ct_name)"
    if ! pct exec "$CT_ID" -- bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      export NEEDRESTART_MODE=a
      export APT_LISTCHANGES_FRONTEND=none
      export UCF_FORCE_CONFOLD=1
      export LANG=C.UTF-8
      export LC_ALL=C.UTF-8

      apt-get -q update
      apt-get \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        -y dist-upgrade
      apt-get -y autoremove --purge
      apt-get -y autoclean
    '; then
      echo "  ERROR: update failed for $CT_ID ($ct_name)" >&2
      failed_list+=("$CT_ID ($ct_name): update failed")
    fi

    if pct exec "$CT_ID" -- bash -lc 'test -e /var/run/reboot-required || test -s /var/run/reboot-required.pkgs' >/dev/null 2>&1; then
      reboot_list+=("$CT_ID ($ct_name)")
    fi
  fi

  if [[ "$STARTED_HERE" -eq 1 ]]; then
    echo "  Shutdown $CT_ID ($ct_name)"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      pct shutdown "$CT_ID" >/dev/null 2>&1 || true
      STARTED_HERE=0
    fi
  fi

done < <(pct list | awk 'NR>1 {print $1, $2}')

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  Done."

if (( ${#bind_mount_skip_list[@]} > 0 )); then
  echo ""
  echo "  Snapshot skipped (host bind mounts — not snapshot-capable):"
  for item in "${bind_mount_skip_list[@]}"; do
    echo "    $item"
  done
fi

if (( ${#snapshot_failed_list[@]} > 0 )); then
  echo ""
  echo "  Snapshot failures:"
  for item in "${snapshot_failed_list[@]}"; do
    echo "    $item"
  done
fi

if (( ${#skipped_by_user_list[@]} > 0 )); then
  echo ""
  echo "  Skipped by user:"
  for item in "${skipped_by_user_list[@]}"; do
    echo "    $item"
  done
fi

if (( ${#skipped_by_script_list[@]} > 0 )); then
  echo ""
  echo "  Skipped by script:"
  for item in "${skipped_by_script_list[@]}"; do
    echo "    $item"
  done
fi

if (( ${#reboot_list[@]} > 0 )); then
  echo ""
  echo "  Containers requiring reboot:"
  for item in "${reboot_list[@]}"; do
    echo "    $item"
  done
fi

if (( ${#failed_list[@]} > 0 )); then
  echo ""
  echo "  Failures:"
  for item in "${failed_list[@]}"; do
    echo "    $item"
  done
  echo ""
  exit 1
fi

echo ""
