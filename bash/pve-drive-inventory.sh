#!/usr/bin/env bash
set -Eeo pipefail

# ── Colours & symbols ─────────────────────────────────────────────────────────
R='\033[0;31m'  RB='\033[1;31m'
G='\033[0;32m'  GB='\033[1;32m'
Y='\033[0;33m'  YB='\033[1;33m'
B='\033[0;34m'  BB='\033[1;34m'
C='\033[0;36m'  CB='\033[1;36m'
W='\033[1;37m'  DIM='\033[2m'
NC='\033[0m'

OK="${GB}✔${NC}"
ERR="${RB}✘${NC}"
WARN="${YB}⚠${NC}"
NVMe="${CB}⚡${NC}"
SSD="${GB}▪${NC}"
HDD="${YB}◉${NC}"
USB="${B}⇄${NC}"
UNKNOWN="${DIM}?${NC}"

HR="${DIM}$(printf '─%.0s' $(seq 1 72))${NC}"

# ── Disk count (needed for banner) ───────────────────────────────────────────
ALL_DISK_COUNT=$(lsblk -dno NAME,TYPE 2>/dev/null \
  | awk '$2 == "disk" && $1 !~ /^(loop|zd)/' | wc -l)

# ── Banner ────────────────────────────────────────────────────────────────────
clear
printf "\n"
printf "  ${CB}╔══════════════════════════════════════════════════════════════════╗${NC}\n"
printf "  ${CB}║${NC}  ${W}PVE Drive Inventory${NC}  ${DIM}$(hostname)  —  $(date '+%Y-%m-%d %H:%M')${NC}$(printf '%*s' $(( 20 - ${#HOSTNAME} > 0 ? 20 - ${#HOSTNAME} : 0 )) '')  ${CB}║${NC}\n"
printf "  ${CB}╚══════════════════════════════════════════════════════════════════╝${NC}\n"
printf "\n  ${DIM}Total disks: ${W}%d${DIM}  │  ${NC}Legend:  ${NVMe} NVMe  ${SSD} SSD  ${HDD} HDD  ${USB} USB\n\n" "$ALL_DISK_COUNT"

# ── Dependency check ──────────────────────────────────────────────────────────
for _cmd in smartctl lsblk bc; do
  command -v "$_cmd" &>/dev/null || printf "  ${WARN} '$_cmd' not found — install it for full output\n"
done

# ── Section 1 — Physical disks ───────────────────────────────────────────────
printf "\n${BB}┌─ ${W}PHYSICAL DISKS${NC}\n${HR}\n"

mapfile -t DISKS < <(lsblk -dno NAME,SIZE,ROTA,TRAN,MODEL,SERIAL 2>/dev/null \
  | awk '$4 != "rom"' | grep -v '^loop' | grep -v '^zd')

DISK_COUNT=0
for line in "${DISKS[@]}"; do
  name=$(awk  '{print $1}' <<<"$line")
  size=$(awk  '{print $2}' <<<"$line")
  rota=$(awk  '{print $3}' <<<"$line")
  tran=$(awk  '{print $4}' <<<"$line")
  model=$(awk '{$1=$2=$3=$4=$NF=""; print}' <<<"$line" | sed 's/^ *//;s/ *$//')
  serial=$(awk '{print $NF}' <<<"$line")

  [[ -b "/dev/$name" ]] || continue
  lsblk -no PKNAME "/dev/$name" 2>/dev/null | grep -q . && continue

  DISK_COUNT=$(( DISK_COUNT + 1 ))

  # drive icon
  if   [[ "$tran" == "nvme" ]]; then icon="$NVMe"
  elif [[ "$tran" == "usb"  ]]; then icon="$USB"
  elif [[ "$rota" == "0"    ]]; then icon="$SSD"
  elif [[ "$rota" == "1"    ]]; then icon="$HDD"
  else                               icon="$UNKNOWN"
  fi

  # SMART health
  if ! command -v smartctl &>/dev/null; then
    health="${DIM}smartctl N/A${NC}"
  else
    _sr=$({ smartctl -H "/dev/$name" 2>/dev/null || true; } | awk '/result:/{print $NF}')
    case "$_sr" in
      PASSED|OK) health="${OK} SMART OK"      ;;
      FAILED*)   health="${ERR} SMART FAILED" ;;
      *)         health="${DIM}SMART: N/A${NC}" ;;
    esac
  fi

  # temperature
  temp=""
  if command -v smartctl &>/dev/null; then
    _tv=$({ smartctl -A "/dev/$name" 2>/dev/null || true; } \
      | awk '/Temperature_Celsius|^190 |^194 /{print $10; exit}')
    [[ -z "$_tv" ]] && _tv=$({ smartctl -A "/dev/$name" 2>/dev/null || true; } \
      | awk '/Temperature:/{print $2; exit}')
    if [[ -n "$_tv" ]]; then
      if   (( _tv >= 60 )); then temp=" ${RB}${_tv}°C${NC}"
      elif (( _tv >= 45 )); then temp=" ${YB}${_tv}°C${NC}"
      else                       temp=" ${GB}${_tv}°C${NC}"
      fi
    fi
  fi

  printf "  ${icon} ${W}/dev/%-8s${NC}  ${C}%12s${NC}  ${DIM}%-28s${NC}  ${DIM}Serial:${NC} %-20s  %b%b\n" \
    "$name" "$size" "${model:-Unknown model}" "${serial:--}" "$health" "$temp"

  # partitions
  while IFS= read -r cname; do
    csize=$(lsblk  -dno SIZE       "/dev/$cname" 2>/dev/null || echo "?")
    cfs=$(lsblk    -dno FSTYPE     "/dev/$cname" 2>/dev/null || echo "")
    cmount=$(lsblk -dno MOUNTPOINT "/dev/$cname" 2>/dev/null || echo "")
    [[ -z "$cfs"    ]] && cfs="-"
    [[ -z "$cmount" ]] && cmount="-"
    printf "      ${DIM}├─${NC} %-14s  %-8s  ${DIM}%-10s${NC}  ${DIM}%s${NC}\n" \
      "$cname" "$csize" "$cfs" "$cmount"
  done < <(lsblk -no NAME "/dev/$name" 2>/dev/null | awk 'NR>1')

done

printf "\n  ${DIM}Standalone (not in any ZFS pool): ${W}%d${NC}\n" "$DISK_COUNT"

# ── Section 2 — ZFS pool members ─────────────────────────────────────────────
if command -v zpool &>/dev/null && zpool list &>/dev/null 2>&1; then
  printf "\n${BB}┌─ ${W}ZFS POOL MEMBERS${NC}\n${HR}\n"

  current_pool=""
  current_role=""
  current_group=""
  _pending_header=""

  while IFS=$'\t' read -r pool role group byid; do

    # pool + role header — buffer it, print below once we know the group
    if [[ "$pool $role" != "$current_pool $current_role" ]]; then
      _pending_header="\n  ${BB}▸${NC} ${W}${pool}${NC}  ${DIM}[${role}]${NC}"
      current_pool="$pool"
      current_role="$role"
      current_group=""
    fi

    # vdev group header
    if [[ "$group" != "$current_group" ]]; then
      if [[ "$group" == "stripe" ]]; then
        _stripe_devs=$(zpool status 2>/dev/null | awk -v p="$pool" '
          /^  pool: / { cur=$2; in_config=0 }
          /^config:/  { if (cur==p) in_config=1; next }
          /^errors:/  { in_config=0; next }
          in_config && ($1 ~ /^(ata|nvme|wwn|scsi|usb|virtio)-/ || $1 ~ /^(sd|hd|vd|nvme|xvd)[a-z0-9]/) { count++ }
          END { print count+0 }
        ')
        if [[ "$_stripe_devs" -le 1 ]]; then
          printf "${_pending_header}  ${RB}single disk ⚠ no redundancy${NC}\n"
        else
          printf "${_pending_header}  ${RB}stripe ⚠ no redundancy${NC}\n"
        fi
      else
        printf "${_pending_header}\n"
        printf "    ${DIM}%s${NC}\n" "$group"
      fi
      _pending_header=""
      current_group="$group"
    fi

    # resolve by-id → /dev/sdX
    local_dev=""
    byid_path="/dev/disk/by-id/${byid}"
    if [[ -L "$byid_path" ]]; then
      local_dev=$(readlink -f "$byid_path" | sed 's|/dev/||')
    else
      [[ -b "/dev/$byid" ]] && local_dev="$byid"
    fi

    if [[ -n "$local_dev" ]]; then
      parent_dev=$(lsblk -no PKNAME "/dev/$local_dev" 2>/dev/null | head -1)
      info_dev="${parent_dev:-$local_dev}"

      # display name: parent disk + [partN] annotation when member is a partition
      if [[ -n "$parent_dev" ]]; then
        display_dev="$parent_dev"
        part_ann="[${local_dev##$parent_dev}]"
      else
        display_dev="$local_dev"
        part_ann=""
      fi

      size=$(lsblk   -dno SIZE   "/dev/$info_dev"  2>/dev/null || echo "?")
      rota=$(lsblk   -dno ROTA   "/dev/$info_dev"  2>/dev/null || echo "")
      tran=$(lsblk   -dno TRAN   "/dev/$info_dev"  2>/dev/null || echo "")
      model=$(lsblk  -dno MODEL  "/dev/$info_dev"  2>/dev/null | sed 's/ *$//' || echo "")
      serial=$(lsblk -dno SERIAL "/dev/$info_dev"  2>/dev/null || echo "-")

      # drive icon
      if   [[ "$tran" == "nvme" ]]; then icon="$NVMe"
      elif [[ "$tran" == "usb"  ]]; then icon="$USB"
      elif [[ "$rota" == "0"    ]]; then icon="$SSD"
      elif [[ "$rota" == "1"    ]]; then icon="$HDD"
      else                               icon="$UNKNOWN"
      fi

      # SMART health — always query the whole disk
      if ! command -v smartctl &>/dev/null; then
        health="${DIM}smartctl N/A${NC}"
      else
        _sr=$({ smartctl -H "/dev/$info_dev" 2>/dev/null || true; } | awk '/result:/{print $NF}')
        case "$_sr" in
          PASSED|OK) health="${OK} SMART OK"      ;;
          FAILED*)   health="${ERR} SMART FAILED" ;;
          *)         health="${DIM}SMART: N/A${NC}" ;;
        esac
      fi

      # temperature — always query the whole disk
      temp=""
      if command -v smartctl &>/dev/null; then
        _tv=$({ smartctl -A "/dev/$info_dev" 2>/dev/null || true; } \
          | awk '/Temperature_Celsius|^190 |^194 /{print $10; exit}')
        [[ -z "$_tv" ]] && _tv=$({ smartctl -A "/dev/$info_dev" 2>/dev/null || true; } \
          | awk '/Temperature:/{print $2; exit}')
        if [[ -n "$_tv" ]]; then
          if   (( _tv >= 60 )); then temp=" ${RB}${_tv}°C${NC}"
          elif (( _tv >= 45 )); then temp=" ${YB}${_tv}°C${NC}"
          else                       temp=" ${GB}${_tv}°C${NC}"
          fi
        fi
      fi

      printf "  ${icon} ${W}/dev/%-8s${NC}  ${DIM}%-5s${NC}${C}%7s${NC}  ${DIM}%-28s${NC}  ${DIM}Serial:${NC} %-20s  %b%b\n" \
        "$display_dev" "$part_ann" "$size" "${model:-Unknown model}" "${serial:--}" "$health" "$temp"
    else
      printf "      ${UNKNOWN} ${DIM}%-40s${NC}  ${DIM}(device not found)${NC}\n" "$byid"
    fi

  done < <(zpool status 2>/dev/null | awk '
    /^  pool: /   { pool=$2; role="data"; group="stripe"; in_config=0 }
    /^config:/    { in_config=1; next }
    /^errors:/    { in_config=0; next }
    !in_config    { next }
    {
      dev=$1
      if (dev == "NAME" || dev == pool)                           { next }
      if (dev == "cache")                                         { role="cache"; group="cache";  next }
      if (dev ~ /^spares?$/)                                      { role="spare"; group="spares"; next }
      if (dev == "log")                                           { role="log";   group="log";    next }
      if (dev == "dedup")                                         { role="dedup"; group="dedup";  next }
      if (dev ~ /^(mirror|raidz[0-9]?|draid)[0-9-]*$/)          { group=dev; next }
      if (dev ~ /^replacing-[0-9]+$/ || dev ~ /^spare-[0-9]+$/) { next }
      if (dev ~ /^(ata|nvme|wwn|scsi|usb|virtio)-/ ||
          dev ~ /^(sd|hd|vd|nvme|xvd)[a-z0-9]/)
        printf "%s\t%s\t%s\t%s\n", pool, role, group, dev
    }
  ')
fi

# ── Section 3 — ZFS pools & datasets ─────────────────────────────────────────
if command -v zpool &>/dev/null && zpool list &>/dev/null 2>&1; then
  printf "\n${BB}┌─ ${W}ZFS POOLS${NC}\n${HR}\n"

  while IFS=$'\t' read -r pname psize palloc pfree pcap phealth; do
    [[ "$pname" == "NAME" || -z "$pname" ]] && continue

    hcolour=$G
    [[ "$phealth" != "ONLINE" ]] && hcolour=$R

    printf "\n  ${BB}▸${NC} ${W}%-20s${NC}  Total: ${C}%8s${NC}  Alloc: ${Y}%9s${NC} Free: ${G}%8s${NC} Health: ${hcolour}%s${NC}\n" \
      "$pname" "$psize" "$palloc" "$pfree" "$phealth"

    # datasets (direct children only)
    while IFS=$'\t' read -r dsname dsused dsavail dsmount; do
      label="${dsname#${pname}/}"
      [[ "$label" == "$dsname" || -z "$label" ]] && continue
      used_h=$(awk  "BEGIN{printf \"%.1fG\", $dsused/1e9}")
      avail_h=$(awk "BEGIN{printf \"%.1fG\", $dsavail/1e9}")
      [[ "$dsmount" == "-" ]] && dsmount="${DIM}(no mountpoint)${NC}"
      printf "    ${DIM}├─${NC} %-42s  ${Y}%8s${NC} used  ${G}%8s${NC} avail  ${DIM}%s${NC}\n" \
        "$label" "$used_h" "$avail_h" "$dsmount"
    done < <(zfs list -H -p -d 1 -o name,used,avail,mountpoint "$pname" 2>/dev/null)

  done < <(zpool list -H -p -o name,size,alloc,free,cap,health 2>/dev/null \
    | awk 'BEGIN{OFS="\t"} {printf "%s\t%.1fG\t%.1fG\t%.1fG\t%d\t%s\n", \
        $1,$2/1e9,$3/1e9,$4/1e9,$5,$6}')
fi

# ── Section 4 — LVM ──────────────────────────────────────────────────────────
if command -v pvs &>/dev/null 2>&1; then
  VGS=$(vgs --noheadings --units g -o vg_name,vg_size,vg_free,pv_count,lv_count 2>/dev/null || true)
  if [[ -n "$VGS" ]]; then
    printf "\n${BB}┌─ ${W}LVM VOLUME GROUPS${NC}\n${HR}\n"
    while IFS= read -r vg; do
      vgname=$(awk  '{print $1}' <<<"$vg")
      vgsize=$(awk  '{print $2}' <<<"$vg")
      vgfree=$(awk  '{print $3}' <<<"$vg")
      pvcount=$(awk '{print $4}' <<<"$vg")
      lvcount=$(awk '{print $5}' <<<"$vg")
      printf "  ${BB}▸${NC} ${W}%-20s${NC}  Size: ${C}%s${NC}  Free: ${G}%s${NC}  PVs: %s  LVs: %s\n" \
        "$vgname" "$vgsize" "$vgfree" "$pvcount" "$lvcount"

      # logical volumes under this VG
      while IFS=$'\t' read -r lvname lvsize lvpath; do
        # get fstype and mountpoint from lsblk
        lvfs=$(lsblk -dno FSTYPE "$lvpath" 2>/dev/null || echo "-")
        lvmount=$(lsblk -dno MOUNTPOINT "$lvpath" 2>/dev/null || echo "-")
        [[ -z "$lvfs"    ]] && lvfs="-"
        [[ -z "$lvmount" ]] && lvmount="-"
        printf "    ${DIM}├─${NC} %-24s  ${C}%8s${NC}  ${DIM}%-10s${NC}  ${DIM}%s${NC}\n" \
          "$lvname" "$lvsize" "$lvfs" "$lvmount"
      done < <(lvs --noheadings --units g -o lv_name,lv_size,lv_path \
        --select "vg_name=$vgname" 2>/dev/null \
        | awk '{printf "%s\t%s\t%s\n", $1, $2, $3}')

    done <<<"$VGS"
  fi
fi

# ── Section 4 — Ceph OSD (if present) ────────────────────────────────────────
if command -v ceph &>/dev/null && ceph status &>/dev/null 2>&1; then
  printf "\n${BB}┌─ ${W}CEPH OSDs${NC}\n${HR}\n"
  ceph osd df 2>/dev/null | head -20 || true
fi

# ── Footer ────────────────────────────────────────────────────────────────────
printf "\n${HR}\n"
printf "  ${DIM}Tip: pipe through 'less -R' to scroll.${NC}\n\n"
