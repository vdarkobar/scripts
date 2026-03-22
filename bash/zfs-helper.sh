#!/usr/bin/env bash
set -Eeo pipefail

# ZFS Pool Creation Helper Script
# This script helps with creating ZFS pools by providing various utilities
# such as checking ZFS installation, listing disks, and assisting with pool creation.
#
# Designed to work on Proxmox VE and other systems - automatically detects if running
# as root and uses sudo only when necessary.

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Shared helpers ──────────────────────────────────────────────────────────────

print_msg() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Run commands with or without sudo based on current user
run_cmd() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Check if a disk ID should be excluded from listings
should_exclude() {
    local disk_id="$1"
    local exclude_patterns=(-part[0-9]+$ lvm-pv-uuid cdrom dvd)
    for pattern in "${exclude_patterns[@]}"; do
        [[ "$disk_id" =~ $pattern ]] && return 0
    done
    return 1
}

# Format a single disk entry for display: "id (canonical, size, model)"
format_disk_info() {
    local disk_id="$1"
    local canonical="$2"
    local size model

    if [[ ! -b "$canonical" ]]; then
        return 1
    fi

    if { read -r size model; } 2>/dev/null < <(lsblk -d -n -o SIZE,MODEL "$canonical" 2>/dev/null); then
        # Strip leading/trailing whitespace only — preserve internal spaces in model names
        size=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$size")
        model=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$model")
        [[ -z "$model" ]] && model="Unknown"
        echo "$disk_id ($canonical, $size, $model)"
    else
        if size=$(lsblk -d -n -o SIZE "$canonical" 2>/dev/null); then
            size=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$size")
            echo "$disk_id ($canonical, $size, Unknown)"
        else
            echo "$disk_id ($canonical)"
        fi
    fi
}

# Populate a nameref array with formatted disk entries.
# Usage: collect_disks result_array_name
# Requires Bash 4.3+ (nameref). Proxmox VE ships Bash 5.x.
collect_disks() {
    local -n _result=$1
    _result=()

    local required_cmds=(find realpath lsblk)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: $cmd not found" >&2
            return 1
        fi
    done

    if [[ -d /dev/disk/by-id ]] && \
       [[ -n "$(find /dev/disk/by-id -maxdepth 1 -type l -print -quit 2>/dev/null)" ]]; then

        declare -A seen_devices
        while IFS= read -r disk_id; do
            should_exclude "$(basename "$disk_id")" && continue
            local canonical
            canonical=$(realpath "$disk_id" 2>/dev/null) || continue
            [[ -b "$canonical" ]] || continue
            [[ -n "${seen_devices[$canonical]+x}" ]] && continue

            local formatted
            if formatted=$(format_disk_info "$disk_id" "$canonical"); then
                _result+=("$formatted")
                seen_devices["$canonical"]=1
            fi
        done < <(find /dev/disk/by-id -maxdepth 1 -type l 2>/dev/null | sort)

    else
        echo "Warning: /dev/disk/by-id not found or empty, falling back to lsblk" >&2
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            local name size model
            read -r name size model <<< "$line"
            [[ -n "$name" ]] || continue
            model="${model:-Unknown}"
            _result+=("/dev/$name (/dev/$name, $size, $model)")
        done < <(lsblk -d -o NAME,SIZE,MODEL -n 2>/dev/null \
                   | grep -vE '^(loop|sr|ram)' | sort)
    fi
}

# Prompt user to type the exact device path to confirm a destructive wipe.
# Returns 0 if confirmed, 1 if not.
confirm_wipe() {
    local canonical_path="$1"
    print_msg "$RED"    "This will permanently destroy all data on $canonical_path."
    print_msg "$YELLOW" "Type the full device path to confirm (e.g. $canonical_path), or press Enter to skip:"
    read -r confirm_path || true
    if [[ "$confirm_path" != "$canonical_path" ]]; then
        print_msg "$YELLOW" "Confirmation did not match. Skipping $canonical_path."
        return 1
    fi
    return 0
}

# ── Disk usage detection ────────────────────────────────────────────────────────

# Return a space-separated string of usage descriptions for a device path.
# Empty output means the disk is not in use.
get_disk_usage() {
    local disk=$1
    local usage=()

    # Extract canonical device path from formatted disk string if needed
    local canonical_path
    if [[ "$disk" =~ \(([^,]+), ]]; then
        canonical_path="${BASH_REMATCH[1]}"
    else
        canonical_path="$disk"
    fi

    # Check if disk is part of a ZFS pool.
    # Match on both full canonical path and basename to handle pools created
    # with by-id paths where canonical_path may not appear verbatim.
    if command -v zpool &>/dev/null; then
        local zpool_status canonical_base
        zpool_status=$(zpool status -P 2>/dev/null)
        canonical_base=$(basename "$canonical_path")
        if echo "$zpool_status" | grep -qF " $canonical_path " || \
           echo "$zpool_status" | grep -qwF "$canonical_base"; then
            local pool
            pool=$(echo "$zpool_status" | awk -v dev="$canonical_path" -v base="$canonical_base" '
                /^  pool:/ { current = $2 }
                index($0, dev) || index($0, base) { print current; exit }
            ')
            usage+=("ZFS pool '${pool:-unknown}'")
        fi
    fi

    # Check if disk or any child partition is mounted (-n suppresses header)
    if lsblk -nr -o MOUNTPOINT "$canonical_path" 2>/dev/null | \
       awk 'NF { found=1 } END { exit !found }'; then
        usage+=("mounted")
    fi

    # Enumerate disk and all child devices (partitions, LVs, etc.) for deeper checks
    local -a all_devs
    mapfile -t all_devs < <(lsblk -nrpo NAME "$canonical_path" 2>/dev/null)

    # Check if any device in the tree is an LVM physical volume.
    # pvs --noheadings emits leading whitespace — trim with awk before matching.
    if command -v pvs &>/dev/null; then
        local -a pv_list
        mapfile -t pv_list < <(run_cmd pvs --noheadings -o pv_name 2>/dev/null \
            | awk '{$1=$1; print}' || true)
        local pv
        for pv in "${all_devs[@]}"; do
            if printf '%s\n' "${pv_list[@]}" | grep -qxF "$pv"; then
                usage+=("LVM physical volume")
                break
            fi
        done
    fi

    # Check if any device in the tree is an md member.
    # /proc/mdstat uses bare names (e.g. sda1[0]), not full paths.
    local dev dev_base
    for dev in "${all_devs[@]}"; do
        dev_base=$(basename "$dev")
        if grep -qwF "$dev_base" /proc/mdstat 2>/dev/null; then
            usage+=("RAID array")
            break
        fi
    done

    # Check for filesystem signatures on disk and all children
    for dev in "${all_devs[@]}"; do
        if run_cmd blkid "$dev" >/dev/null 2>&1; then
            usage+=("has filesystem")
            break
        fi
    done

    echo "${usage[@]}"
}

# ── ZFS installation checks ─────────────────────────────────────────────────────

check_zfs_installed() {
    print_msg "$BLUE" "Checking if ZFS is installed..."

    if command -v zpool &>/dev/null && command -v zfs &>/dev/null; then
        print_msg "$GREEN" "✓ ZFS is installed."
        return 0
    else
        print_msg "$RED" "✗ ZFS is not installed."

        if [ -f /etc/debian_version ]; then
            print_msg "$YELLOW" "To install ZFS on Debian/Ubuntu, run:"
            echo "apt update && apt install zfsutils-linux"
        elif [ -f /etc/redhat-release ]; then
            print_msg "$YELLOW" "To install ZFS on RHEL/CentOS/Fedora, run:"
            echo "dnf install epel-release"
            echo "dnf install zfs"
        elif [ -f /etc/arch-release ]; then
            print_msg "$YELLOW" "To install ZFS on Arch Linux, run:"
            echo "pacman -S zfs-dkms zfs-utils"
        else
            print_msg "$YELLOW" "Please install ZFS according to your distribution's documentation."
        fi

        return 1
    fi
}

check_zfs_version() {
    print_msg "$BLUE" "Checking ZFS version..."

    if command -v zpool &>/dev/null; then
        local zpool_version zfs_version
        zpool_version=$(zpool version)
        zfs_version=$(zfs version 2>/dev/null || echo "N/A")

        print_msg "$GREEN" "ZFS Pool version: ${zpool_version}"
        print_msg "$GREEN" "ZFS Filesystem version: ${zfs_version}"

        if [ -f /proc/kallsyms ]; then
            local module_version
            module_version=$(modinfo zfs 2>/dev/null | grep -E "^version:" | awk '{print $2}')
            if [ -n "$module_version" ]; then
                print_msg "$GREEN" "ZFS kernel module version: ${module_version}"
            fi
        fi
    else
        print_msg "$RED" "Cannot check ZFS version - ZFS not installed."
        return 1
    fi
}

# ── Disk listing ────────────────────────────────────────────────────────────────

list_disks_by_id() {
    print_msg "$BLUE" "Listing all disks by ID..."

    local disk_ids=()
    collect_disks disk_ids || return 1

    if [[ ${#disk_ids[@]} -eq 0 ]]; then
        print_msg "$RED" "No disks found."
        return 1
    fi

    print_msg "$GREEN" "Found ${#disk_ids[@]} unique disks:"
    printf "%-60s %-20s %-10s %-20s\n" "DISK ID" "DEVICE" "SIZE" "MODEL"
    echo "----------------------------------------------------------------------------------------------------"

    for disk_info in "${disk_ids[@]}"; do
        if [[ "$disk_info" =~ ^(.+)\ \(([^,]+),\ ([^,]+),\ (.+)\)$ ]]; then
            local short_id device size model
            short_id=$(basename "${BASH_REMATCH[1]}")
            device="${BASH_REMATCH[2]}"
            size="${BASH_REMATCH[3]}"
            model="${BASH_REMATCH[4]}"
            printf "%-60s %-20s %-10s %-20s\n" "$short_id" "$device" "$size" "$model"
        fi
    done
}

# ── Disk info ───────────────────────────────────────────────────────────────────

show_disk_info() {
    print_msg "$BLUE" "Enter the device name to get detailed information (e.g., sda, nvme0n1):"
    read -r disk_name || true

    if [[ ! "$disk_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        print_msg "$RED" "Invalid device name '$disk_name'. Use only alphanumeric characters, hyphens, or dots (e.g., sda, nvme0n1, dm-0)."
        return 1
    fi

    if [[ ! -b "/dev/$disk_name" ]]; then
        print_msg "$RED" "Device /dev/$disk_name not found or not a block device."
        return 1
    fi

    print_msg "$GREEN" "Detailed information for /dev/$disk_name:"
    echo "---------------------------------------------------------"

    echo "BASIC INFO:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL "/dev/$disk_name"

    echo -e "\nPARTITION TABLE:"
    run_cmd fdisk -l "/dev/$disk_name" 2>/dev/null \
        || print_msg "$YELLOW" "Cannot get partition info (requires root privileges)."

    echo -e "\nSMART INFO (if available):"
    if command -v smartctl &>/dev/null; then
        run_cmd smartctl -a "/dev/$disk_name" 2>/dev/null \
            || print_msg "$YELLOW" "Cannot get SMART info (requires root privileges or smartmontools)."
    else
        print_msg "$YELLOW" "smartmontools not installed. Install with: apt install smartmontools"
    fi
}

# ── Disk zapping ────────────────────────────────────────────────────────────────

zap_disk() {
    local disk=$1

    local canonical_path
    if [[ "$disk" =~ \(([^,]+), ]]; then
        canonical_path="${BASH_REMATCH[1]}"
    else
        canonical_path="$disk"
    fi

    print_msg "$YELLOW" "Wiping disk $canonical_path..."

    # Clear ZFS labels if present
    run_cmd zpool labelclear -f "$canonical_path" 2>/dev/null || true

    # Prefer sgdisk for GPT/MBR table removal (handles both start and end of disk)
    if command -v sgdisk &>/dev/null; then
        run_cmd sgdisk --zap-all "$canonical_path" 2>/dev/null || true
    fi

    # Clear all filesystem and partition signatures
    run_cmd wipefs -af "$canonical_path"

    # Zero the first and last 10 MiB to catch both MBR/GPT header and GPT backup
    local disk_size_bytes
    disk_size_bytes=$(lsblk -dn -o SIZE --bytes "$canonical_path" 2>/dev/null || echo 0)
    run_cmd dd if=/dev/zero of="$canonical_path" bs=1M count=10 2>/dev/null
    if (( disk_size_bytes > 20971520 )); then
        run_cmd dd if=/dev/zero of="$canonical_path" bs=1M \
            seek=$(( (disk_size_bytes / 1048576) - 10 )) count=10 2>/dev/null
    fi

    # Discard all blocks if device supports it (SSD/NVMe)
    if command -v blkdiscard &>/dev/null; then
        run_cmd blkdiscard "$canonical_path" 2>/dev/null || true
    fi

    # Re-read partition table and settle udev
    run_cmd partprobe "$canonical_path" 2>/dev/null || true
    udevadm settle 2>/dev/null || true

    print_msg "$GREEN" "Disk $canonical_path wiped (signatures cleared, partition metadata removed)."
}

zap_disks() {
    print_msg "$BLUE" "Disk Zapping Utility"
    print_msg "$BLUE" "-------------------"

    local disk_ids=()
    collect_disks disk_ids || return 1

    if [ ${#disk_ids[@]} -eq 0 ]; then
        print_msg "$RED" "No disks found."
        return 1
    fi

    print_msg "$BLUE" "Available disks:"
    for i in "${!disk_ids[@]}"; do
        local disk usage status
        disk="${disk_ids[$i]}"
        usage=$(get_disk_usage "$disk")
        status=$( [ -z "$usage" ] && echo "Not in use" || echo "In use: $usage" )
        printf "%2d) %s - %s\n" "$i" "$disk" "$status"
    done

    print_msg "$BLUE" "Enter disk numbers to zap (space-separated, or 'q' to quit):"
    read -r selection || true

    if [ "$selection" = "q" ]; then
        print_msg "$GREEN" "Operation cancelled."
        return
    fi

    local -a selections
    read -ra selections <<< "$selection"

    for num in "${selections[@]}"; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -lt "${#disk_ids[@]}" ]]; then
            local disk usage canonical_path
            disk="${disk_ids[$num]}"
            usage=$(get_disk_usage "$disk")

            # Extract canonical path for confirm_wipe
            if [[ "$disk" =~ \(([^,]+), ]]; then
                canonical_path="${BASH_REMATCH[1]}"
            else
                canonical_path="$disk"
            fi

            if [ -z "$usage" ]; then
                confirm_wipe "$canonical_path" || continue
                zap_disk "$disk"
            else
                print_msg "$RED" "Disk $disk is in use: $usage"
                if echo "$usage" | grep -qF "mounted"; then
                    print_msg "$RED" "Warning: Wiping a mounted disk can lead to system instability."
                fi
                if echo "$usage" | grep -qF "ZFS pool"; then
                    print_msg "$RED" "Warning: Wiping a disk in an imported ZFS pool can corrupt the pool."
                fi
                confirm_wipe "$canonical_path" || continue
                zap_disk "$disk"
            fi
        else
            print_msg "$RED" "Invalid selection: $num"
        fi
    done
}

# ── ZFS pool creation ───────────────────────────────────────────────────────────

create_zfs_pool() {
    if ! check_zfs_installed; then
        return 1
    fi

    print_msg "$BLUE" "ZFS Pool Creation Wizard"
    print_msg "$BLUE" "------------------------"

    # Step 1: Pool name
    print_msg "$YELLOW" "Enter the name for your ZFS pool:"
    read -r pool_name || true

    if [ -z "$pool_name" ]; then
        print_msg "$RED" "Pool name cannot be empty."
        return 1
    fi

    if [[ ! "$pool_name" =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]]; then
        print_msg "$RED" "Invalid pool name '$pool_name'. Must start with a letter and contain only alphanumerics, hyphens, underscores, or periods."
        return 1
    fi

    local reserved_names=(mirror raidz raidz2 raidz3 spare log cache special dedup)
    for reserved in "${reserved_names[@]}"; do
        if [[ "$pool_name" == "$reserved" ]]; then
            print_msg "$RED" "Pool name '$pool_name' is a reserved ZFS keyword."
            return 1
        fi
    done

    if zpool list -H -o name 2>/dev/null | grep -qxF "$pool_name"; then
        print_msg "$RED" "A pool named '$pool_name' already exists."
        return 1
    fi

    # Step 2: Pool type
    print_msg "$YELLOW" "Select pool type:"
    echo "1) stripe (no redundancy, maximum space)"
    echo "2) mirror (n-way mirroring)"
    echo "3) raidz (similar to RAID5, single parity)"
    echo "4) raidz2 (similar to RAID6, double parity)"
    echo "5) raidz3 (triple parity)"
    read -r pool_type_num || true

    local pool_type
    case $pool_type_num in
        1) pool_type="" ;;
        2) pool_type="mirror" ;;
        3) pool_type="raidz" ;;
        4) pool_type="raidz2" ;;
        5) pool_type="raidz3" ;;
        *) print_msg "$RED" "Invalid selection."; return 1 ;;
    esac

    # Step 3: Select disks
    print_msg "$YELLOW" "Do you want to use disk IDs (more reliable) or device names?"
    echo "1) Disk IDs (e.g., /dev/disk/by-id/ata-...)"
    echo "2) Device names (e.g., /dev/sda)"
    read -r disk_selection_type || true

    if [[ ! "$disk_selection_type" =~ ^[12]$ ]]; then
        print_msg "$RED" "Invalid selection. Please enter 1 or 2."
        return 1
    fi

    local selected_disks=()
    if [[ "$disk_selection_type" == "1" ]]; then
        list_disks_by_id
        print_msg "$YELLOW" "Enter the disk IDs to use, separated by spaces (e.g., 'ata-Disk1 ata-Disk2'):"
        read -r selected_disks_input || true

        local -a input_disks
        read -ra input_disks <<< "$selected_disks_input"
        for disk in "${input_disks[@]}"; do
            local full_path="/dev/disk/by-id/$disk"
            if [ -L "$full_path" ]; then
                selected_disks+=("$full_path")
            else
                print_msg "$RED" "Disk ID '$disk' not found. Please verify the ID."
                return 1
            fi
        done
    else
        print_msg "$YELLOW" "Available disks:"
        lsblk -dn -o NAME,SIZE,MODEL | grep -vE '^(loop|sr|ram)'
        print_msg "$YELLOW" "Enter the device names to use, separated by spaces (e.g., 'sda sdb'):"
        read -r selected_disks_input || true

        local -a input_disks
        read -ra input_disks <<< "$selected_disks_input"
        for disk in "${input_disks[@]}"; do
            local full_path="/dev/$disk"
            if [ -b "$full_path" ]; then
                selected_disks+=("$full_path")
            else
                print_msg "$RED" "Device '$disk' not found. Please verify the device name."
                return 1
            fi
        done
    fi

    if [ ${#selected_disks[@]} -eq 0 ]; then
        print_msg "$RED" "No valid disks selected."
        return 1
    fi

    # Deduplicate selected disks by canonical path
    declare -A _seen_selected
    local deduped_disks=()
    for disk in "${selected_disks[@]}"; do
        local real
        real=$(readlink -f "$disk" 2>/dev/null || echo "$disk")
        if [[ -n "${_seen_selected[$real]+x}" ]]; then
            print_msg "$RED" "Duplicate disk selected: $real. Each disk may only appear once."
            return 1
        fi
        _seen_selected["$real"]=1
        deduped_disks+=("$disk")
    done
    selected_disks=("${deduped_disks[@]}")

    # Check minimum disk requirements based on pool type
    case $pool_type in
        "mirror")
            if [ ${#selected_disks[@]} -lt 2 ]; then
                print_msg "$RED" "Mirror requires at least 2 disks."
                return 1
            fi
            ;;
        "raidz")
            if [ ${#selected_disks[@]} -lt 3 ]; then
                print_msg "$RED" "RAIDZ requires at least 3 disks."
                return 1
            fi
            ;;
        "raidz2")
            if [ ${#selected_disks[@]} -lt 4 ]; then
                print_msg "$RED" "RAIDZ2 requires at least 4 disks."
                return 1
            fi
            ;;
        "raidz3")
            if [ ${#selected_disks[@]} -lt 5 ]; then
                print_msg "$RED" "RAIDZ3 requires at least 5 disks."
                return 1
            fi
            ;;
    esac

    # Check all selected disks for in-use status before asking to proceed
    local in_use_found=0
    for disk in "${selected_disks[@]}"; do
        local real_device usage
        real_device=$(readlink -f "$disk" 2>/dev/null || echo "$disk")
        usage=$(get_disk_usage "$real_device")
        if [ -n "$usage" ]; then
            print_msg "$RED" "Disk $real_device is in use: $usage"
            in_use_found=1
        fi
    done

    if (( in_use_found )); then
        print_msg "$YELLOW" "One or more selected disks appear to be in use. Continue anyway? (y/N)"
        read -r continue_choice || true
        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            print_msg "$RED" "Pool creation aborted."
            return 1
        fi
    fi

    # Step 4: Additional options
    print_msg "$YELLOW" "Do you want to specify additional pool options? (y/n)"
    read -r add_options_choice || true

    local options=()
    if [[ "$add_options_choice" =~ ^[Yy]$ ]]; then
        print_msg "$YELLOW" "Enter ashift value (9=512B, 12=4K, 13=8K, or leave blank for auto):"
        read -r ashift || true
        if [ -n "$ashift" ]; then
            if [[ ! "$ashift" =~ ^[0-9]+$ ]] || [[ "$ashift" -lt 9 || "$ashift" -gt 16 ]]; then
                print_msg "$RED" "Invalid ashift value '$ashift'. Must be a number between 9 and 16."
                return 1
            fi
            options+=(-o "ashift=$ashift")
        fi

        print_msg "$YELLOW" "Enable compression? (y/n)"
        read -r compression_choice || true
        if [[ "$compression_choice" =~ ^[Yy]$ ]]; then
            options+=(-O compression=lz4)
        fi

        print_msg "$YELLOW" "Enable autotrim? (y/n)"
        read -r autotrim_choice || true
        if [[ "$autotrim_choice" =~ ^[Yy]$ ]]; then
            options+=(-o autotrim=on)
        fi

        print_msg "$YELLOW" "Enable autoexpand? (y/n)"
        read -r autoexpand_choice || true
        if [[ "$autoexpand_choice" =~ ^[Yy]$ ]]; then
            options+=(-o autoexpand=on)
        fi

        print_msg "$YELLOW" "Enable atime? (y/n, 'n' is recommended for better performance)"
        read -r atime_choice || true
        if [[ ! "$atime_choice" =~ ^[Yy]$ ]]; then
            options+=(-O atime=off)
        fi

        print_msg "$YELLOW" "Additional custom options (e.g., '-O recordsize=128K'):"
        read -r custom_options || true
        if [ -n "$custom_options" ]; then
            # Word-split user's free-form input — best effort
            local -a custom_array
            read -ra custom_array <<< "$custom_options"
            options+=("${custom_array[@]}")
        fi
    else
        options=(-o ashift=12 -O compression=lz4 -O atime=off)
    fi

    # Step 5: Review and confirm
    print_msg "$BLUE" "Pool Creation Summary:"
    echo "Pool name: $pool_name"
    echo "Pool type: ${pool_type:-stripe}"
    echo "Selected disks: ${selected_disks[*]}"
    echo "Options: ${options[*]}"

    print_msg "$YELLOW" "Create the pool with these settings? (y/n)"
    read -r confirm || true

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local cmd_parts=("zpool" "create" "$pool_name")
        cmd_parts+=("${options[@]}")
        if [ -n "$pool_type" ]; then
            cmd_parts+=("$pool_type")
        fi
        cmd_parts+=("${selected_disks[@]}")

        print_msg "$BLUE" "Executing: run_cmd ${cmd_parts[*]}"

        if run_cmd "${cmd_parts[@]}"; then
            print_msg "$GREEN" "Successfully created ZFS pool '$pool_name'."
            echo "Pool status:"
            zpool status "$pool_name"
        else
            print_msg "$RED" "Failed to create ZFS pool. See error above."
            return 1
        fi
    else
        print_msg "$YELLOW" "Pool creation cancelled."
        return 1
    fi
}

# ── Pool status ─────────────────────────────────────────────────────────────────

show_pool_status() {
    if ! check_zfs_installed; then
        return 1
    fi

    print_msg "$BLUE" "ZFS Pool Status"
    print_msg "$BLUE" "---------------"

    if ! zpool list 2>/dev/null; then
        print_msg "$YELLOW" "No ZFS pools found."
        return 0
    fi

    print_msg "$YELLOW" "Enter pool name to see detailed status (or press Enter to return):"
    read -r pool_name || true

    if [ -z "$pool_name" ]; then
        return 0
    fi

    if ! zpool list -H -o name 2>/dev/null | grep -qxF "$pool_name"; then
        print_msg "$RED" "Pool '$pool_name' not found."
        return 1
    fi

    zpool status "$pool_name"
    echo
    zfs list -r "$pool_name"
}

# ── Pool destruction ────────────────────────────────────────────────────────────

destroy_pool() {
    if ! check_zfs_installed; then
        return 1
    fi

    print_msg "$BLUE" "ZFS Pool Destruction"
    print_msg "$BLUE" "------------------"

    zpool list

    local pool_name
    print_msg "$YELLOW" "Enter the name of the pool to destroy (or press Enter to cancel):"
    read -r pool_name || true
    if [ -z "$pool_name" ]; then
        print_msg "$YELLOW" "Operation cancelled."
        return 0
    fi

    if ! zpool list -H -o name 2>/dev/null | grep -qxF "$pool_name"; then
        print_msg "$RED" "Pool '$pool_name' not found."
        return 1
    fi

    print_msg "$RED" "WARNING: This will destroy the pool '$pool_name' and all data it contains!"
    print_msg "$RED" "Type the pool name again to confirm:"
    read -r confirm_name || true

    if [ "$pool_name" != "$confirm_name" ]; then
        print_msg "$YELLOW" "Pool names do not match. Operation cancelled."
        return 1
    fi

    print_msg "$YELLOW" "Force destruction? (y/n)"
    read -r force_choice || true

    local force_opts=()
    if [[ "$force_choice" =~ ^[Yy]$ ]]; then
        force_opts=(-f)
    fi

    print_msg "$BLUE" "Executing: run_cmd zpool destroy ${force_opts[*]} $pool_name"

    if run_cmd zpool destroy "${force_opts[@]}" "$pool_name"; then
        print_msg "$GREEN" "Successfully destroyed ZFS pool '$pool_name'."
    else
        print_msg "$RED" "Failed to destroy ZFS pool. See error above."
        return 1
    fi
}

# ── Pool export / import ────────────────────────────────────────────────────────

export_import_pool() {
    if ! check_zfs_installed; then
        return 1
    fi

    print_msg "$BLUE" "ZFS Pool Export/Import"
    print_msg "$BLUE" "---------------------"

    echo "1) Export a pool"
    echo "2) Import a pool"
    read -r export_import_choice || true

    case $export_import_choice in
        1)
            zpool list

            local pool_name
            print_msg "$YELLOW" "Enter the name of the pool to export (or press Enter to cancel):"
            read -r pool_name || true
            if [ -z "$pool_name" ]; then
                print_msg "$YELLOW" "Operation cancelled."
                return 0
            fi

            if ! zpool list -H -o name 2>/dev/null | grep -qxF "$pool_name"; then
                print_msg "$RED" "Pool '$pool_name' not found."
                return 1
            fi

            print_msg "$YELLOW" "Force export? (y/n)"
            read -r force_choice || true

            local force_opts=()
            if [[ "$force_choice" =~ ^[Yy]$ ]]; then
                force_opts=(-f)
            fi

            print_msg "$BLUE" "Executing: run_cmd zpool export ${force_opts[*]} $pool_name"

            if run_cmd zpool export "${force_opts[@]}" "$pool_name"; then
                print_msg "$GREEN" "Successfully exported ZFS pool '$pool_name'."
            else
                print_msg "$RED" "Failed to export ZFS pool. See error above."
                return 1
            fi
            ;;

        2)
            print_msg "$BLUE" "Scanning for importable pools..."

            if ! run_cmd zpool import; then
                print_msg "$RED" "No importable pools found or error scanning."
                return 1
            fi

            local pool_name
            print_msg "$YELLOW" "Enter the name of the pool to import (or press Enter to cancel):"
            read -r pool_name || true
            if [ -z "$pool_name" ]; then
                print_msg "$YELLOW" "Operation cancelled."
                return 0
            fi

            print_msg "$YELLOW" "Import with a different name? (y/n)"
            read -r rename_choice || true

            local new_name=""
            if [[ "$rename_choice" =~ ^[Yy]$ ]]; then
                print_msg "$YELLOW" "Enter new pool name:"
                read -r new_name || true
            fi

            if [ -n "$new_name" ]; then
                print_msg "$BLUE" "Executing: run_cmd zpool import $pool_name $new_name"
                if run_cmd zpool import "$pool_name" "$new_name"; then
                    print_msg "$GREEN" "Successfully imported ZFS pool as '$new_name'."
                else
                    print_msg "$RED" "Failed to import ZFS pool. See error above."
                    return 1
                fi
            else
                print_msg "$BLUE" "Executing: run_cmd zpool import $pool_name"
                if run_cmd zpool import "$pool_name"; then
                    print_msg "$GREEN" "Successfully imported ZFS pool."
                else
                    print_msg "$RED" "Failed to import ZFS pool. See error above."
                    return 1
                fi
            fi
            ;;

        *)
            print_msg "$RED" "Invalid selection."
            return 1
            ;;
    esac
}

# ── Pool scrub ──────────────────────────────────────────────────────────────────

scrub_pool() {
    if ! check_zfs_installed; then
        return 1
    fi

    print_msg "$BLUE" "ZFS Pool Scrub"
    print_msg "$BLUE" "--------------"

    zpool list

    local pool_name
    print_msg "$YELLOW" "Enter the name of the pool to scrub (or press Enter to cancel):"
    read -r pool_name || true
    if [ -z "$pool_name" ]; then
        print_msg "$YELLOW" "Operation cancelled."
        return 0
    fi

    if ! zpool list -H -o name 2>/dev/null | grep -qxF "$pool_name"; then
        print_msg "$RED" "Pool '$pool_name' not found."
        return 1
    fi

    print_msg "$BLUE" "Executing: run_cmd zpool scrub $pool_name"

    if run_cmd zpool scrub "$pool_name"; then
        print_msg "$GREEN" "Scrub started on pool '$pool_name'."
        print_msg "$GREEN" "You can check the status with 'zpool status $pool_name'."
    else
        print_msg "$RED" "Failed to start scrub. See error above."
        return 1
    fi
}

# ── Main menu ───────────────────────────────────────────────────────────────────

main_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "          ZFS Pool Creation Helper        "
        echo "=========================================="
        echo
        echo "1) Check ZFS installation"
        echo "2) Check ZFS version"
        echo "3) List disks by ID"
        echo "4) Show detailed disk information"
        echo "5) Zap/Wipe disks"
        echo "6) Create a ZFS pool"
        echo "7) Show ZFS pool status"
        echo "8) Destroy a ZFS pool"
        echo "9) Export/Import a ZFS pool"
        echo "10) Scrub a ZFS pool"
        echo "0) Exit"
        echo
        print_msg "$YELLOW" "Enter your choice [0-10]:"
        read -r choice || true

        case $choice in
            1)  check_zfs_installed  || true ;;
            2)  check_zfs_version    || true ;;
            3)  list_disks_by_id     || true ;;
            4)  show_disk_info       || true ;;
            5)  zap_disks            || true ;;
            6)  create_zfs_pool      || true ;;
            7)  show_pool_status     || true ;;
            8)  destroy_pool         || true ;;
            9)  export_import_pool   || true ;;
            10) scrub_pool           || true ;;
            0)  echo "Exiting."; exit 0 ;;
            *)  print_msg "$RED" "Invalid choice. Please try again." ;;
        esac

        echo
        print_msg "$YELLOW" "Press Enter to continue..."
        read -r || true
    done
}

# ── Entry point ─────────────────────────────────────────────────────────────────
main_menu
