#!/usr/bin/env bash
set -Eeo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
ASSUME_YES=0
EXCLUDE_IDS=""
STOP_TIMEOUT=30    # seconds to wait for container to stop

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1; shift ;;
    -x|--exclude) shift; EXCLUDE_IDS="${EXCLUDE_IDS} ${1:-}"; shift ;;
    -h|--help)    cat <<'EOF'
Usage: deletelxc.sh [OPTIONS]

  -y, --yes           Skip confirmation prompt
  -x, --exclude ID    Exclude a container ID (repeatable)
  -h, --help          Show this help

EOF
      exit 0 ;;
    *) echo "  ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── Preflight — root & commands ───────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
  echo "  ERROR: Must be run as root." >&2; exit 1
fi
for cmd in pct awk whiptail; do
  command -v "$cmd" >/dev/null 2>&1 \
    || { echo "  ERROR: Required command not found: $cmd" >&2; exit 1; }
done

# ── Discover containers ───────────────────────────────────────────────────────
# pct list columns: VMID STATUS LOCK NAME
mapfile -t CT_LINES < <(pct list | awk 'NR>1 {print $1, $2, $NF}')

if [[ ${#CT_LINES[@]} -eq 0 ]]; then
  whiptail --title "LXC Container Delete" --msgbox "No LXC containers available!" 10 60
  exit 0
fi

# ── Build checklist ───────────────────────────────────────────────────────────
menu_items=("ALL" "Delete ALL containers" "OFF")

for line in "${CT_LINES[@]}"; do
  read -r ct_id ct_status ct_name <<< "$line"
  [[ " $EXCLUDE_IDS " == *" $ct_id "* ]] && continue
  label=$(printf "%-20s  [%s]" "$ct_name" "$ct_status")
  menu_items+=("$ct_id" "$label" "OFF")
done

CHOICES=$(whiptail \
  --title "LXC Container Delete" \
  --checklist "Select containers to delete:" \
  25 60 15 \
  "${menu_items[@]}" \
  3>&2 2>&1 1>&3)

if [[ -z "$CHOICES" ]]; then
  echo "  No containers selected."
  exit 0
fi

# ── Resolve selection — deduplicated array ────────────────────────────────────
selected_ids=()

# Strip whiptail quoting safely
read -r -a raw_tokens <<< "${CHOICES//\"/}"

if [[ " ${raw_tokens[*]} " == *" ALL "* ]]; then
  for line in "${CT_LINES[@]}"; do
    read -r ct_id _ <<< "$line"
    [[ " $EXCLUDE_IDS " == *" $ct_id "* ]] && continue
    selected_ids+=("$ct_id")
  done
else
  for id in "${raw_tokens[@]}"; do
    [[ " ${selected_ids[*]:-} " == *" $id "* ]] && continue  # deduplicate
    selected_ids+=("$id")
  done
fi

if [[ ${#selected_ids[@]} -eq 0 ]]; then
  echo "  No valid containers selected."
  exit 0
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
if [[ $ASSUME_YES -eq 0 ]]; then
  whiptail \
    --title "LXC Container Delete" \
    --yesno "Delete the following containers?\n\n  ${selected_ids[*]}\n\nThis is irreversible." \
    15 60
  # whiptail returns 0 for Yes, 1 for No/Cancel
  # shellcheck disable=SC2181
  [[ $? -eq 0 ]] || { echo "  Cancelled."; exit 0; }
fi

# ── State vars for trap ───────────────────────────────────────────────────────
CURRENT_CT=""

# ── Trap ──────────────────────────────────────────────────────────────────────
trap 'trap - ERR
  rc=$?
  echo "  ERROR: failed (rc=$rc) near line ${BASH_LINENO[0]:-?}" >&2
  echo "  Command: $BASH_COMMAND" >&2
  [[ -n "$CURRENT_CT" ]] && echo "  Last container: $CURRENT_CT" >&2
  exit $rc' ERR

trap 'echo; echo "  Interrupted."; exit 130' INT TERM

# ── Delete containers ─────────────────────────────────────────────────────────
echo
failed_list=""

for id in "${selected_ids[@]}"; do
  CURRENT_CT="$id"

  ct_status=$(pct status "$id" 2>/dev/null | awk '{print $2}')

  if [[ "$ct_status" == "running" ]]; then
    echo "  [$id] Stopping..."
    pct stop "$id" --timeout "$STOP_TIMEOUT" 2>/dev/null || true
    for i in $(seq 1 "$STOP_TIMEOUT"); do
      st=$(pct status "$id" 2>/dev/null | awk '{print $2}')
      [[ "$st" == "stopped" ]] && break
      sleep 1
    done
    st=$(pct status "$id" 2>/dev/null | awk '{print $2}')
    if [[ "$st" != "stopped" ]]; then
      msg="Container $id did not stop within ${STOP_TIMEOUT}s — skipping."
      echo "  [$id] ERROR: $msg" >&2
      whiptail --title "Error" --msgbox "$msg" 10 60
      failed_list+="$id (did not stop)\n"
      continue
    fi
  fi

  echo "  [$id] Deleting..."
  if pct destroy "$id" 2>/dev/null; then
    echo "  [$id] Deleted."
  else
    msg="Failed to delete container $id."
    echo "  [$id] ERROR: $msg" >&2
    whiptail --title "Error" --msgbox "$msg" 10 60
    failed_list+="$id (destroy failed)\n"
  fi
done

CURRENT_CT=""

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "  Deletion process completed."
if [[ -n "$failed_list" ]]; then
  echo "  Failures:" >&2
  printf "%b" "$failed_list" | sed 's/^/    /' >&2
  exit 1
fi
