#!/bin/bash
#===============================================================================
# PATCH OMARCHY ISO FOR DUAL-BOOT
#
# This version hooks into the original Omarchy installer (archinstall)
# We just handle partitioning, then let archinstall do everything else
#
# Usage: sudo ./patch-omarchy-dualboot.sh omarchy-3.x.x.iso
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -ne 0 ]] && error "Run as root: sudo $0"

# Auto-detect ISO if not provided
if [[ -z "$1" ]]; then
    SOURCE_ISO=$(find "$SCRIPT_DIR" -maxdepth 1 -name "omarchy-*.iso" ! -name "omarchy-dualboot-*" ! -name "omarchy-installer-*" ! -name "win-omarchy-*" 2>/dev/null | head -1)
    if [[ -z "$SOURCE_ISO" ]]; then
        error "No Omarchy ISO found in $SCRIPT_DIR

Please either:
  1. Place omarchy-*.iso in the same directory as this script
  2. Or specify the path: sudo $0 /path/to/omarchy.iso"
    fi
    log "Auto-detected ISO: $(basename "$SOURCE_ISO")"
else
    SOURCE_ISO="$1"
fi

[[ ! -f "$SOURCE_ISO" ]] && error "ISO not found: $SOURCE_ISO"
WORK_DIR="$SCRIPT_DIR/.omarchy-patch-$$"
OUTPUT_ISO="$SCRIPT_DIR/win-omarchy-$(date +%Y.%m.%d).iso"

# Check and install dependencies
MISSING_PKGS=""
command -v xorriso &>/dev/null || MISSING_PKGS="$MISSING_PKGS xorriso"
command -v unsquashfs &>/dev/null || MISSING_PKGS="$MISSING_PKGS squashfs-tools"
command -v isoinfo &>/dev/null || MISSING_PKGS="$MISSING_PKGS cdrtools"

if [[ -n "$MISSING_PKGS" ]]; then
    log "Installing missing dependencies:$MISSING_PKGS"
    pacman -S --noconfirm --needed $MISSING_PKGS || error "Failed to install dependencies"
    log "Dependencies installed"
fi

log "Patching: $SOURCE_ISO"

# Cleanup on exit
cleanup() {
    umount "$WORK_DIR/iso" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"/{iso,extracted,newiso}

#===============================================================================
# EXTRACT ISO
#===============================================================================

log "Extracting ISO..."
mount -o loop,ro "$SOURCE_ISO" "$WORK_DIR/iso"
cp -a "$WORK_DIR/iso/"* "$WORK_DIR/newiso/"
umount "$WORK_DIR/iso"

# Find squashfs
SQUASHFS="$WORK_DIR/newiso/arch/x86_64/airootfs.sfs"
[[ ! -f "$SQUASHFS" ]] && error "Squashfs not found at expected path"

log "Extracting squashfs (this takes a few minutes)..."
unsquashfs -d "$WORK_DIR/extracted" "$SQUASHFS"

# Verify squashfs structure
if [[ ! -d "$WORK_DIR/extracted/root" ]]; then
    error "Unexpected squashfs structure: /root directory not found!"
fi

log "Original /root contents:"
ls -la "$WORK_DIR/extracted/root/" | grep -E '\.(zlogin|zprofile|automated|bash)' || echo "  (no matching files)"

#===============================================================================
# CREATE DUAL-BOOT WRAPPER SCRIPT
#===============================================================================

log "Creating dual-boot wrapper..."

# This script runs BEFORE the original installer
# It handles partitioning, then lets archinstall do the rest
cat > "$WORK_DIR/extracted/root/dualboot-setup.sh" << 'DUALBOOT_SCRIPT'
#!/bin/bash
#===============================================================================
# DUAL-BOOT PARTITION SETUP
# Creates partitions in free space, then hands off to archinstall
#===============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

cleanup_and_exit() {
    warn "Setup cancelled or failed. Cleaning up..."
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    exit 1
}

#===============================================================================
# CLEANUP FUNCTION FOR FAILED INSTALLATIONS
#===============================================================================

cleanup_failed_install() {
    header "CLEANUP FAILED INSTALLATION"

    echo "This will remove Linux partitions from a failed installation attempt."
    echo "Windows partitions will NOT be touched."
    echo ""

    echo "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL | grep -E "^(nvme|sd|vd)"
    echo ""

    read -p "Enter drive to clean (e.g., nvme0n1): " drive_input
    DRIVE="/dev/$drive_input"

    [[ ! -b "$DRIVE" ]] && error "Drive not found: $DRIVE"
    [[ "$DRIVE" == *"nvme"* ]] && PART_PREFIX="${DRIVE}p" || PART_PREFIX="$DRIVE"

    echo ""
    echo "Current partitions:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL "$DRIVE"
    echo ""

    cryptsetup close cryptroot 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true

    LINUX_EFI=""
    LINUX_ROOT=""

    for part in ${PART_PREFIX}*; do
        [[ "$part" == "$DRIVE" || "$part" == "${PART_PREFIX}" ]] && continue
        [[ ! -b "$part" ]] && continue

        LABEL=$(lsblk -n -o LABEL "$part" 2>/dev/null | tr -d ' ')
        FSTYPE=$(lsblk -n -o FSTYPE "$part" 2>/dev/null | tr -d ' ')

        if [[ "$LABEL" == "LINUXEFI" ]]; then
            LINUX_EFI="$part"
            echo -e "${YELLOW}Found Linux EFI partition: $part${NC}"
        elif [[ "$FSTYPE" == "crypto_LUKS" ]]; then
            LINUX_ROOT="$part"
            echo -e "${YELLOW}Found LUKS partition: $part${NC}"
        fi
    done

    if [[ -z "$LINUX_EFI" && -z "$LINUX_ROOT" ]]; then
        echo ""
        info "No Linux partitions found from failed installation."
        read -p "Press Enter to continue..." _
        return 1
    fi

    echo ""
    echo -e "${RED}WARNING: The following partitions will be DELETED:${NC}"
    [[ -n "$LINUX_EFI" ]] && echo "  - $LINUX_EFI (Linux EFI)"
    [[ -n "$LINUX_ROOT" ]] && echo "  - $LINUX_ROOT (Linux Root/LUKS)"
    echo ""

    read -p "Type 'DELETE' to confirm removal: " confirm
    if [[ "$confirm" != "DELETE" ]]; then
        echo "Cancelled."
        return 1
    fi

    if [[ -n "$LINUX_ROOT" ]]; then
        PART_NUM=$(echo "$LINUX_ROOT" | grep -oE '[0-9]+$')
        log "Deleting partition $PART_NUM..."
        sgdisk -d "$PART_NUM" "$DRIVE"
    fi

    if [[ -n "$LINUX_EFI" ]]; then
        PART_NUM=$(echo "$LINUX_EFI" | grep -oE '[0-9]+$')
        log "Deleting partition $PART_NUM..."
        sgdisk -d "$PART_NUM" "$DRIVE"
    fi

    partprobe "$DRIVE"

    for entry in $(efibootmgr 2>/dev/null | grep -i "Omarchy" | sed -n 's/^Boot\([0-9A-Fa-f]*\).*/\1/p'); do
        efibootmgr -b "$entry" -B 2>/dev/null || true
    done

    # Restore the genuine Windows bootloader if the install spoofed it. The
    # dual-boot install replaces \EFI\Microsoft\Boot\bootmgfw.efi with Limine
    # and saves the real loader as bootmgfwbackup.efi. Without restoring it,
    # removing the Linux partitions leaves a now-configless Limine as Windows'
    # bootloader and Windows won't boot. The Windows ESP is never deleted, so
    # the backup is still there.
    log "Restoring genuine Windows bootloader if it was spoofed..."
    for part in ${PART_PREFIX}*; do
        [[ "$part" == "$DRIVE" || "$part" == "${PART_PREFIX}" ]] && continue
        [[ ! -b "$part" ]] && continue
        [[ "$(lsblk -no FSTYPE "$part" 2>/dev/null)" != "vfat" ]] && continue
        RMNT=$(mktemp -d)
        if mount "$part" "$RMNT" 2>/dev/null; then
            WB="$RMNT/EFI/Microsoft/Boot"
            if [[ -f "$WB/bootmgfwbackup.efi" ]]; then
                if cp "$WB/bootmgfwbackup.efi" "$WB/bootmgfw.efi"; then
                    rm -f "$WB/bootmgfwbackup.efi"
                    sync
                    log "Restored genuine Windows bootloader on $part"
                else
                    warn "Failed to restore bootmgfw.efi on $part — Windows may not boot!"
                fi
            fi
            umount "$RMNT"
        fi
        rmdir "$RMNT"
    done

    log "Cleanup complete!"
    echo ""
    lsblk -o NAME,SIZE,FSTYPE,LABEL "$DRIVE"
    echo ""
    read -p "Press Enter to continue..." _
    return 0
}

#===============================================================================
# REPAIR DUAL-BOOT (re-apply the bootmgfw spoof after a Windows update)
#===============================================================================
#
# A Windows feature update can reinstall \EFI\Microsoft\Boot\bootmgfw.efi,
# overwriting our Limine spoof. The machine then boots straight to Windows and
# the Limine menu disappears. This repair re-installs Limine over bootmgfw.efi
# (refreshing the backup with the now-current Windows loader) so Limine loads
# first again. Neither Windows nor the Omarchy install is otherwise touched.

repair_dualboot() {
    header "REPAIR DUAL-BOOT — RE-APPLY LIMINE"

    echo "Use this if the machine started booting straight to Windows and the"
    echo "Limine menu disappeared (usually after a Windows feature update"
    echo "overwrote the boot file)."
    echo ""
    echo "This re-installs Limine as the Windows boot file. Windows and your"
    echo "Omarchy install are NOT modified."
    echo ""

    echo "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL | grep -E "^(nvme|sd|vd)"
    echo ""
    read -p "Enter the drive with the dual-boot install (e.g., nvme0n1): " drive_input
    DRIVE="/dev/$drive_input"
    [[ ! -b "$DRIVE" ]] && error "Drive not found: $DRIVE"
    [[ "$DRIVE" == *"nvme"* ]] && PART_PREFIX="${DRIVE}p" || PART_PREFIX="$DRIVE"

    # Locate the LINUXEFI partition (holds Limine + limine.conf) and the Windows
    # ESP (holds bootmgfw.efi).
    LINUXEFI_PART=""
    WIN_ESP_PART=""
    WIN_ESP_PARTUUID=""
    for part in ${PART_PREFIX}*; do
        [[ "$part" == "$DRIVE" || "$part" == "${PART_PREFIX}" ]] && continue
        [[ ! -b "$part" ]] && continue
        [[ "$(lsblk -no FSTYPE "$part" 2>/dev/null)" != "vfat" ]] && continue
        if [[ "$(lsblk -no LABEL "$part" 2>/dev/null | tr -d ' ')" == "LINUXEFI" ]]; then
            LINUXEFI_PART="$part"
            continue
        fi
        TMP=$(mktemp -d)
        if mount -o ro "$part" "$TMP" 2>/dev/null; then
            [[ -f "$TMP/EFI/Microsoft/Boot/bootmgfw.efi" ]] && {
                WIN_ESP_PART="$part"
                WIN_ESP_PARTUUID=$(lsblk -no PARTUUID "$part")
            }
            umount "$TMP"
        fi
        rmdir "$TMP"
    done

    [[ -z "$LINUXEFI_PART" ]] && error "LINUXEFI partition not found on $DRIVE — is this the right drive?"
    [[ -z "$WIN_ESP_PART" ]] && error "Windows ESP (with bootmgfw.efi) not found on $DRIVE"
    log "LINUXEFI:    $LINUXEFI_PART"
    log "Windows ESP: $WIN_ESP_PART (PARTUUID=$WIN_ESP_PARTUUID)"

    # Pull the exact Limine binary from the install's LINUXEFI partition.
    LMNT=$(mktemp -d)
    mount -o ro "$LINUXEFI_PART" "$LMNT" || error "Could not mount $LINUXEFI_PART"
    LIMINE_SRC="$LMNT/EFI/BOOT/BOOTX64.EFI"
    if [[ ! -f "$LIMINE_SRC" ]]; then
        umount "$LMNT"; rmdir "$LMNT"
        error "Limine EFI not found at LINUXEFI:/EFI/BOOT/BOOTX64.EFI"
    fi
    cp "$LIMINE_SRC" /tmp/limine-repair.efi
    umount "$LMNT"; rmdir "$LMNT"

    # Re-apply the spoof on the Windows ESP.
    WMNT=$(mktemp -d)
    mount "$WIN_ESP_PART" "$WMNT" || error "Could not mount $WIN_ESP_PART"
    WB="$WMNT/EFI/Microsoft/Boot"

    if cmp -s "$WB/bootmgfw.efi" /tmp/limine-repair.efi; then
        log "bootmgfw.efi is already Limine — spoof is intact, no repair needed"
        echo ""
        info "If the Limine menu still doesn't appear, the cause is the firmware"
        info "boot order, not the spoof. Use the firmware boot menu (F8/F11/F12)"
        info "to select 'Windows Boot Manager' once — it will load Limine."
    else
        log "bootmgfw.efi is the Windows loader — re-applying the spoof"
        # Refresh the backup with the CURRENT (post-update) Windows loader so the
        # Windows menu entry chainloads the newest genuine loader.
        if cp "$WB/bootmgfw.efi" "$WB/bootmgfwbackup.efi"; then
            log "Saved current Windows loader -> bootmgfwbackup.efi"
        else
            warn "Could not refresh bootmgfwbackup.efi — keeping any existing backup"
        fi
        if cp /tmp/limine-repair.efi "$WB/bootmgfw.efi"; then
            sync
            log "Installed Limine as bootmgfw.efi — Limine will load first on next boot"
        else
            umount "$WMNT"; rmdir "$WMNT"; rm -f /tmp/limine-repair.efi
            error "Failed to install Limine over bootmgfw.efi"
        fi
    fi
    umount "$WMNT"; rmdir "$WMNT"
    rm -f /tmp/limine-repair.efi

    # Make sure limine.conf still has a Windows entry pointing at the backup.
    # limine.conf lives on LINUXEFI and isn't touched by Windows updates, so this
    # is just a safety net for an edge case.
    CMNT=$(mktemp -d)
    if mount "$LINUXEFI_PART" "$CMNT" 2>/dev/null; then
        if [[ -f "$CMNT/limine.conf" ]] && ! grep -q "bootmgfwbackup.efi" "$CMNT/limine.conf"; then
            warn "limine.conf has no Windows entry — adding one"
            cat >> "$CMNT/limine.conf" <<WINREPAIR

/Windows Boot Manager
    comment: Chainload the genuine Windows bootloader from the Windows ESP
    protocol: efi_chainload
    image_path: guid($WIN_ESP_PARTUUID):/EFI/Microsoft/Boot/bootmgfwbackup.efi
WINREPAIR
            sync
        fi
        umount "$CMNT"
    fi
    rmdir "$CMNT"

    echo ""
    log "Repair finished — reboot to get the Limine menu back"
    echo ""
    read -p "Press Enter to continue..." _
    return 0
}

#===============================================================================
# MAIN MENU
#===============================================================================

header "OMARCHY DUAL-BOOT INSTALLER"

echo "This installer will set up Omarchy alongside Windows."
echo "Windows partitions will NOT be touched."
echo ""
echo "Options:"
echo "  1) Dual Boot (Heaven and Hell mode) — install Omarchy alongside Windows"
echo "  2) Consider that a divorce (remove a failed install)"
echo "  3) Nuke the site from orbit — it's the only way to be sure (wipe drive, install Omarchy)"
echo "  4) Exit to Ghost in the... (drop to a terminal)"
echo "  5) I'll be back (re-apply Limine after a Windows update)"
echo ""
read -p "Select option [1]: " MENU_CHOICE
MENU_CHOICE=${MENU_CHOICE:-1}

case $MENU_CHOICE in
    2)
        cleanup_failed_install || true
        exec /root/dualboot-setup.sh
        ;;
    3)
        # Run original installer
        info "Starting standard Omarchy installer..."
        exec /root/.automated_script.sh.orig
        ;;
    4)
        echo "Type '/root/dualboot-setup.sh' to restart installer."
        exit 0
        ;;
    5)
        repair_dualboot || true
        exec /root/dualboot-setup.sh
        ;;
    1)
        # Continue with dual-boot setup
        ;;
    *)
        exec /root/dualboot-setup.sh
        ;;
esac

#===============================================================================
# PRE-FLIGHT CHECKS
#===============================================================================

[[ ! -d /sys/firmware/efi ]] && error "UEFI mode required for dual-boot"

# Secure Boot check — Limine BOOTX64.EFI is unsigned, so firmware with
# Secure Boot enabled will silently reject it and fall through to the
# Windows Boot Manager, defeating the whole "Limine is the bootloader"
# design. Detect it now so the user can disable it in firmware first.
SB_STATE="unknown"
if command -v mokutil &>/dev/null; then
    SB_STATE=$(mokutil --sb-state 2>/dev/null | head -1)
elif [[ -d /sys/firmware/efi/efivars ]]; then
    SB_VAR=$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SecureBoot-*' 2>/dev/null | head -1)
    if [[ -n "$SB_VAR" ]]; then
        # 4-byte attributes header, then 1 byte: 0x00 = disabled, 0x01 = enabled
        SB_BYTE=$(od -An -tu1 -j4 -N1 "$SB_VAR" 2>/dev/null | tr -d ' ')
        case "$SB_BYTE" in
            1) SB_STATE="SecureBoot enabled" ;;
            0) SB_STATE="SecureBoot disabled" ;;
        esac
    fi
fi

if echo "$SB_STATE" | grep -qi "enabled"; then
    warn "Secure Boot is ENABLED in firmware."
    echo ""
    echo "  Limine is unsigned. With Secure Boot on, the firmware will"
    echo "  silently reject Limine on every boot and fall through to"
    echo "  Windows Boot Manager — defeating this installer's whole point."
    echo ""
    echo "  Reboot, enter firmware setup (F2/Del), DISABLE Secure Boot,"
    echo "  then re-run this installer."
    echo ""
    read -p "Continue anyway (not recommended)? (y/N): " sb_cont
    [[ ! "$sb_cont" =~ ^[Yy]$ ]] && error "Cancelled — disable Secure Boot first"
else
    log "Secure Boot: $SB_STATE"
fi

header "SELECT DRIVE"

echo "Available drives:"
echo ""
lsblk -d -o NAME,SIZE,MODEL | grep -E "^(nvme|sd|vd)"
echo ""

mapfile -t DRIVES < <(lsblk -d -n -o NAME,TRAN | awk '$2!="usb" {print $1}' | grep -E "^(nvme|sd|vd)")

if [[ ${#DRIVES[@]} -eq 1 ]]; then
    DRIVE="/dev/${DRIVES[0]}"
    info "Found: $DRIVE"
    read -p "Use this drive? (Y/n): " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && error "Cancelled"
else
    read -p "Enter drive (e.g., nvme0n1): " drive_input
    DRIVE="/dev/$drive_input"
fi

[[ ! -b "$DRIVE" ]] && error "Drive not found: $DRIVE"
[[ "$DRIVE" == *"nvme"* ]] && PART_PREFIX="${DRIVE}p" || PART_PREFIX="$DRIVE"

echo ""
echo "Current partitions on $DRIVE:"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$DRIVE"
echo ""

# Check for Windows
if lsblk -o FSTYPE "$DRIVE" | grep -q ntfs; then
    log "Windows detected - it will be preserved"

    # BitLocker + TPM/PCR warning. Changing the boot path (and what the
    # firmware loads first) changes the TPM PCR measurements Windows
    # uses to unseal the BitLocker key. On next Windows boot this can
    # demand the 48-digit recovery key. Same chain of consequences
    # applies if Windows uses TPM-backed device encryption (default on
    # most Win 11 OEM installs) even without explicit BitLocker setup.
    header "BITLOCKER / DEVICE ENCRYPTION WARNING"

    echo "Windows 11 typically has BitLocker or 'Device Encryption' on"
    echo "by default, sealed to the TPM and current boot configuration."
    echo ""
    echo "After this install:"
    echo "  • Limine becomes the first thing the firmware loads"
    echo "  • TPM PCR measurements (PCR 4/7) will differ"
    echo "  • Next Windows boot can demand the 48-digit recovery key"
    echo ""
    echo -e "${BOLD}Before continuing, in Windows:${NC}"
    echo -e "  1. Sign in and open ${BOLD}Settings → Privacy → Find My Device${NC}"
    echo "     and confirm your BitLocker recovery key is saved to your"
    echo "     Microsoft account (or print/save it locally)."
    echo "  2. Open an admin PowerShell and run:"
    echo -e "       ${CYAN}manage-bde -protectors -disable C: -RebootCount 0${NC}"
    echo "     This suspends BitLocker until you re-enable it from Windows."
    echo "  3. Shut down Windows fully (not 'restart' — Fast Startup will"
    echo "     leave the NTFS dirty and Windows will run chkdsk on next boot)."
    echo ""
    echo "If you skip this and don't have the recovery key, you may be"
    echo "permanently locked out of your Windows installation."
    echo ""
    read -p "Type 'I HAVE MY RECOVERY KEY' to continue: " bl_confirm
    if [[ "$bl_confirm" != "I HAVE MY RECOVERY KEY" ]]; then
        error "Cancelled — back up your BitLocker recovery key first"
    fi
else
    warn "Windows not detected on this drive"
    read -p "Continue anyway? (y/N): " cont
    [[ ! "$cont" =~ ^[Yy]$ ]] && error "Cancelled"
fi

# Check free space
FREE_SECTORS=$(sgdisk -p "$DRIVE" 2>/dev/null | grep "Total free space" | awk '{print $5}')
if [[ "$FREE_SECTORS" =~ ^[0-9]+$ ]]; then
    FREE_GB=$((FREE_SECTORS * 512 / 1024 / 1024 / 1024))
    [[ $FREE_GB -lt 20 ]] && error "Need 20GB+ free space, found ${FREE_GB}GB"
    log "Free space: ${FREE_GB}GB"
else
    warn "Could not determine free space"
fi

#===============================================================================
# ENCRYPTION PASSWORD
#===============================================================================

header "DISK ENCRYPTION"

echo "Your Linux partition will be encrypted with LUKS2."
echo "You'll enter your user password in the next step (configurator)."
echo ""

while true; do
    read -s -p "Enter LUKS encryption password: " LUKS_PASS; echo ""
    read -s -p "Confirm password: " LUKS_PASS2; echo ""
    [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && break
    warn "Passwords don't match, try again"
done

#===============================================================================
# CONFIRMATION
#===============================================================================

header "CONFIRM PARTITIONING"

echo "The following will be created in FREE SPACE on $DRIVE:"
echo ""
echo "  • 1GB EFI partition (for Linux bootloader)"
echo "  • Rest: LUKS2 encrypted partition (for Linux root)"
echo ""
echo -e "${GREEN}Windows partitions will NOT be touched.${NC}"
echo ""
read -p "Type 'yes' to continue: " confirm
[[ "$confirm" != "yes" ]] && error "Cancelled"

#===============================================================================
# CREATE PARTITIONS
#===============================================================================

header "CREATING PARTITIONS"

trap cleanup_and_exit ERR

DRIVE_NAME=$(basename "$DRIVE")
LAST_PART=$(lsblk -n -o NAME "$DRIVE" | grep -v "^${DRIVE_NAME}$" | grep -oE '[0-9]+$' | sort -n | tail -1)
LAST_PART=${LAST_PART:-0}

# Create EFI partition
log "Creating Linux EFI partition (1GB)..."
NEXT=$((LAST_PART + 1))
sgdisk -n "${NEXT}:0:+1G" -t "${NEXT}:ef00" "$DRIVE"
EFI_PART="${PART_PREFIX}${NEXT}"
partprobe "$DRIVE"; udevadm settle; sleep 2
mkfs.fat -F32 -n "LINUXEFI" "$EFI_PART"
log "Created: $EFI_PART"

# Create root partition
log "Creating Linux root partition..."
NEXT=$((NEXT + 1))
sgdisk -n "${NEXT}:0:0" -t "${NEXT}:8300" "$DRIVE"
ROOT_PART="${PART_PREFIX}${NEXT}"
partprobe "$DRIVE"; udevadm settle; sleep 2
log "Created: $ROOT_PART"

#===============================================================================
# SETUP ENCRYPTION & FILESYSTEM
#===============================================================================

header "SETTING UP ENCRYPTION"

log "Formatting LUKS2..."
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --key-file=- "$ROOT_PART"

log "Opening encrypted volume..."
echo -n "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" cryptroot
LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")

log "Creating btrfs filesystem..."
mkfs.btrfs -f /dev/mapper/cryptroot

log "Creating subvolumes..."
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
# NOTE: Do NOT create @snapshots - snapper will create .snapshots as nested subvolume
umount /mnt

log "Mounting filesystems..."
mount -o compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,boot}
mount -o compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o compress=zstd,subvol=@log /dev/mapper/cryptroot /mnt/var/log
mount -o compress=zstd,subvol=@pkg /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
# NOTE: Do NOT mount .snapshots - snapper creates it as nested subvolume in @
mount "$EFI_PART" /mnt/boot

log "Partitions ready!"

# Save info for later
echo "$LUKS_UUID" > /tmp/luks_uuid
echo "$EFI_PART" > /tmp/efi_part
echo "$ROOT_PART" > /tmp/root_part
echo "$DRIVE" > /tmp/install_drive

trap - ERR

#===============================================================================
# HAND OFF TO ARCHINSTALL
#===============================================================================

header "STARTING OMARCHY INSTALLER"

echo "Partitions are ready. Now the Omarchy installer will collect your"
echo "user information and install the system."
echo ""
info "The disk is already partitioned - just enter your user details."
echo ""
read -p "Press Enter to continue to Omarchy setup..." _

# Run the configurator to get user info.
# The configurator is a separate child process that re-sources its helpers via
# $OMARCHY_INSTALL and calls helper functions like clear_logo. Without these
# exported it prints "/helpers/all.sh: No such file or directory" and repeated
# "clear_logo: command not found" noise. Export them using Omarchy's own
# convention (OMARCHY_INSTALL=$OMARCHY_PATH/install) so the configurator runs
# clean.
cd /root
export OMARCHY_PATH=/root/omarchy
export OMARCHY_INSTALL=/root/omarchy/install
source "$OMARCHY_INSTALL/helpers/all.sh" 2>/dev/null || true

# Set colors
if [[ $(tty) == "/dev/tty"* ]]; then
    echo -en "\e]P01a1b26"
    echo -en "\e]P7a9b1d6"
    echo -en "\e]PFc0caf5"
    echo -en "\033[0m"
    clear
fi

# Drain any buffered keystrokes / stray terminal bytes left over from the
# "Press Enter" prompt and the logo animation, so they don't leak into the
# configurator's first input field (was showing up as a phantom "A" in the
# Username prompt before the user typed anything).
read -r -t 0.2 -N 100000 _drain 2>/dev/null || true

# Run configurator
./configurator

# Get username from generated config
OMARCHY_USER=$(jq -r '.users[0].username' user_credentials.json 2>/dev/null)

if [[ -z "$OMARCHY_USER" || "$OMARCHY_USER" == "null" ]]; then
    error "Failed to get username from configurator"
fi

log "User: $OMARCHY_USER"

#===============================================================================
# MODIFY CONFIG FOR PRE-MOUNTED PARTITIONS
#===============================================================================

header "CONFIGURING INSTALLATION"

log "Updating configuration for dual-boot..."

# Only modify disk_config and remove bootloader, preserve everything else from generated config
# This keeps the correct kernel, locale, packages, profile, etc.
# We MUST remove bootloader because archinstall crashes when trying to
# detect root device with pre_mounted_config - it fails BEFORE installing packages
# We install limine manually after archinstall completes
jq '.disk_config = {"config_type": "pre_mounted_config", "mountpoint": "/mnt"} | del(.bootloader)' \
    user_configuration.json > user_configuration.json.tmp
mv user_configuration.json.tmp user_configuration.json

# Extract kernel name for later use in bootloader config
KERNEL_NAME=$(jq -r '.kernels[0] // "linux"' user_configuration.json)
echo "$KERNEL_NAME" > /tmp/kernel_name
log "Using kernel: $KERNEL_NAME"

log "Configuration updated for pre-mounted partitions"

#===============================================================================
# RUN ARCHINSTALL
#===============================================================================

header "INSTALLING SYSTEM"

log "Running archinstall..."
info "This will take several minutes..."

# Initialize keyring
pacman-key --init
pacman-key --populate archlinux
pacman-key --populate omarchy 2>/dev/null || true

# For offline install, ensure we use the offline-only pacman config
# and skip database sync since the database is already on the ISO
cat > /tmp/pacman-offline.conf << 'PACCONF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[offline]
SigLevel = Optional TrustAll
Server = file:///var/cache/omarchy/mirror/offline/
PACCONF

# Overwrite system pacman.conf with offline-only version
cp /tmp/pacman-offline.conf /etc/pacman.conf

# Debug: verify config
log "Pacman config set to offline-only:"
grep -E "^\[|^Server" /etc/pacman.conf

# Skip pacman -Sy for offline install - database already exists on ISO
# Check for either offline.db or offline.db.tar.gz
if [[ -f /var/cache/omarchy/mirror/offline/offline.db ]] || [[ -f /var/cache/omarchy/mirror/offline/offline.db.tar.gz ]]; then
    log "Offline package database found - skipping sync"
else
    warn "Offline database not found - attempting sync..."
    pacman --config /tmp/pacman-offline.conf -Sy --noconfirm
fi

# Run archinstall with our config (same flags as original Omarchy installer)
# bootloader=none prevents archinstall from crashing on pre_mounted_config
archinstall \
    --config user_configuration.json \
    --creds user_credentials.json \
    --silent \
    --skip-ntp \
    --skip-wkd \
    --skip-wifi-check

# Verify archinstall created the user
if [[ ! -d /mnt/home/$OMARCHY_USER ]]; then
    error "archinstall failed - user $OMARCHY_USER not created"
fi

log "Base system installed!"

# Install limine bootloader package (archinstall didn't because we removed bootloader config)
log "Installing limine bootloader..."
# Copy offline pacman config to chroot and mount offline mirror first
cp /tmp/pacman-offline.conf /mnt/etc/pacman.conf
mkdir -p /mnt/var/cache/omarchy/mirror/offline
mount --bind /var/cache/omarchy/mirror/offline /mnt/var/cache/omarchy/mirror/offline
# Install limine using offline repo (no -Sy needed, packages are local)
arch-chroot /mnt pacman --noconfirm --needed -S limine

#===============================================================================
# POST-INSTALL CONFIGURATION
#===============================================================================

header "CONFIGURING BOOTLOADER"

LUKS_UUID=$(cat /tmp/luks_uuid)
KERNEL_NAME=$(cat /tmp/kernel_name)

# Configure mkinitcpio for encryption using Omarchy's drop-in approach
log "Configuring initramfs for encryption..."

# Install required packages
log "Installing plymouth and limine tools..."
arch-chroot /mnt pacman --noconfirm --needed -S plymouth limine-snapper-sync limine-mkinitcpio-hook || warn "Some packages may already be installed"

# Create Omarchy-style mkinitcpio drop-in config with encryption support
# This uses the same hooks as Omarchy but includes encrypt for LUKS
mkdir -p /mnt/etc/mkinitcpio.conf.d
cat > /mnt/etc/mkinitcpio.conf.d/omarchy_hooks.conf << 'MKINIT'
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs)
MKINIT

cat > /mnt/etc/mkinitcpio.conf.d/thunderbolt_module.conf << 'MKINIT'
MODULES+=(thunderbolt)
MKINIT

# Rebuild initramfs (warnings about missing firmware are OK)
log "Building initramfs (warnings about missing firmware are normal)..."
if ! arch-chroot /mnt mkinitcpio -P; then
    warn "mkinitcpio reported warnings - checking if initramfs was created..."
fi

# Verify the initramfs was actually created for our kernel
if [[ -f /mnt/boot/initramfs-${KERNEL_NAME}.img ]]; then
    log "initramfs-${KERNEL_NAME}.img created successfully"
elif [[ -f /mnt/boot/initramfs-linux.img ]]; then
    log "initramfs-linux.img created successfully"
else
    error "initramfs was not created! Check mkinitcpio output above."
fi

# Verify kernel was installed
if [[ ! -f /mnt/boot/vmlinuz-$KERNEL_NAME ]]; then
    error "Kernel vmlinuz-$KERNEL_NAME not found in /mnt/boot/"
fi
log "Found kernel: vmlinuz-$KERNEL_NAME"

# Configure Limine bootloader using Omarchy's approach
log "Configuring Limine bootloader..."
mkdir -p /mnt/boot/EFI/BOOT /mnt/boot/EFI/limine

# Copy Limine EFI files
cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT/
cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/limine/

# Create /etc/default/limine for limine-update (Omarchy style)
CRYPT_CMDLINE="cryptdevice=UUID=$LUKS_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@"
cat > /mnt/etc/default/limine << LIMINEDEF
TARGET_OS_NAME="Omarchy"

ESP_PATH="/boot"

KERNEL_CMDLINE[default]="$CRYPT_CMDLINE rw quiet splash"

ENABLE_UKI=yes
CUSTOM_UKI_NAME="omarchy"

ENABLE_LIMINE_FALLBACK=yes

# Find and add other bootloaders (Windows)
FIND_BOOTLOADERS=yes

BOOT_ORDER="*, *fallback, Snapshots"

MAX_SNAPSHOT_ENTRIES=5

SNAPSHOT_FORMAT_CHOICE=5
LIMINEDEF

# Create base limine.conf (limine-update will add entries)
cat > /mnt/boot/limine.conf << 'LIMINE'
default_entry: 2
interface_branding: Omarchy Bootloader
interface_branding_color: 2
hash_mismatch_panic: no

term_background: 1a1b26
backdrop: 1a1b26

term_palette: 15161e;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;a9b1d6
term_palette_bright: 414868;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;c0caf5

term_foreground: c0caf5
term_foreground_bright: c0caf5
term_background_bright: 24283b
LIMINE

# Run limine-update to generate boot entries (including snapshots)
log "Running limine-update to generate boot entries..."
arch-chroot /mnt limine-update || warn "limine-update had issues"

# Enable btrfs quota for space-aware snapshot cleanup
log "Enabling btrfs quota..."
btrfs quota enable /mnt || warn "Could not enable btrfs quota"

#===============================================================================
# INSTALL OMARCHY
#===============================================================================

header "INSTALLING OMARCHY PACKAGES"

# Mount offline mirror if available
if [[ -d /var/cache/omarchy/mirror/offline ]]; then
    mkdir -p /mnt/var/cache/omarchy/mirror/offline
    mount --bind /var/cache/omarchy/mirror/offline /mnt/var/cache/omarchy/mirror/offline
fi

if [[ -d /opt/packages ]]; then
    mkdir -p /mnt/opt/packages
    mount --bind /opt/packages /mnt/opt/packages
fi

# Backup system pacman.conf and use ISO's version temporarily for offline install
cp /mnt/etc/pacman.conf /mnt/etc/pacman.conf.bak
cp /etc/pacman.conf /mnt/etc/pacman.conf

# Copy omarchy to user's home
mkdir -p /mnt/home/$OMARCHY_USER/.local/share/
cp -a /root/omarchy /mnt/home/$OMARCHY_USER/.local/share/
# Ensure all scripts are executable
chmod -R +x /mnt/home/$OMARCHY_USER/.local/share/omarchy/bin/
chmod -R +x /mnt/home/$OMARCHY_USER/.local/share/omarchy/install/
find /mnt/home/$OMARCHY_USER/.local/share/omarchy -name "*.sh" -exec chmod +x {} \;
arch-chroot /mnt chown -R $OMARCHY_USER:$OMARCHY_USER /home/$OMARCHY_USER/.local/

# Get user info from configurator-generated files
USER_FULL_NAME=""
USER_EMAIL=""
[[ -f /root/user_full_name.txt ]] && USER_FULL_NAME=$(<user_full_name.txt)
[[ -f /root/user_email_address.txt ]] && USER_EMAIL=$(<user_email_address.txt)
OMARCHY_MIRROR=""
[[ -f /root/omarchy_mirror ]] && OMARCHY_MIRROR=$(<omarchy_mirror)

# Run omarchy installer in chroot (with proper environment like original installer).
# Pass OMARCHY_CHROOT_INSTALL=1 and the rest on the sudo command line — `sudo -E`
# alone isn't enough because sudo's default env_reset strips unknown vars regardless.
# Without OMARCHY_CHROOT_INSTALL=1 the install/post-install/finished.sh script
# prompts the user with a gum-confirm "Reboot Now" dialog and then runs
# `sudo reboot`, which kills the archiso live env before our wrapper can finish
# (no plymouth/snapper/Windows entry/BootOrder lock would ever run).
log "Installing Omarchy packages and configuration..."
arch-chroot /mnt /bin/bash -c "
    export HOME=/home/$OMARCHY_USER
    export USER=$OMARCHY_USER
    cd /home/$OMARCHY_USER/.local/share/omarchy
    sudo -u $OMARCHY_USER \
        OMARCHY_CHROOT_INSTALL=1 \
        OMARCHY_USER_NAME='$USER_FULL_NAME' \
        OMARCHY_USER_EMAIL='$USER_EMAIL' \
        OMARCHY_MIRROR='$OMARCHY_MIRROR' \
        bash -c 'source install.sh' || true
" || warn "Omarchy install script had some issues (this may be OK)"

# Set up proper pacman.conf for the installed system
log "Configuring pacman for installed system..."
cat > /mnt/etc/pacman.conf << 'PACMANCONF'
[options]
Color
ILoveCandy
VerbosePkgLists
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 5
DownloadUser = alpm

SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch
PACMANCONF

# Set up mirrorlist
cat > /mnt/etc/pacman.d/mirrorlist << 'MIRRORLIST'
Server = https://stable-mirror.omarchy.org/$repo/os/$arch
MIRRORLIST

log "Pacman configured with Omarchy stable repos"

# Now that Omarchy is installed, set Plymouth theme and rebuild initramfs
log "Setting Omarchy Plymouth theme..."
if [[ -d /mnt/usr/share/plymouth/themes/omarchy ]]; then
    arch-chroot /mnt plymouth-set-default-theme omarchy
    log "Rebuilding initramfs with Omarchy Plymouth theme..."
    arch-chroot /mnt mkinitcpio -P
else
    warn "Omarchy Plymouth theme not found"
fi

#===============================================================================
# FINAL SETUP
#===============================================================================

header "FINAL CONFIGURATION"

# Enable services
log "Enabling services..."
arch-chroot /mnt systemctl enable sddm 2>/dev/null || true
arch-chroot /mnt systemctl enable NetworkManager 2>/dev/null || true
arch-chroot /mnt systemctl enable iwd 2>/dev/null || true
arch-chroot /mnt systemctl enable bluetooth 2>/dev/null || true

# Snapper configuration
log "Installing and configuring snapper..."
arch-chroot /mnt pacman --noconfirm --needed -S snapper 2>/dev/null || true

# Create snapper config for root - this creates .snapshots as nested subvolume in @
# --no-dbus is required: the arch-iso environment has no running DBus daemon,
# so snapper's default IPC path fails with org.freedesktop.DBus.Error.ServiceUnknown.
log "Creating snapper root config..."
arch-chroot /mnt snapper --no-dbus -c root create-config / || warn "snapper create-config had issues"

# Enable snapper services
arch-chroot /mnt systemctl enable snapper-cleanup.timer 2>/dev/null || true
arch-chroot /mnt systemctl enable snapper-timeline.timer 2>/dev/null || true
arch-chroot /mnt systemctl enable limine-snapper-sync.service 2>/dev/null || true

# Create initial snapshot
log "Creating initial snapshot..."
arch-chroot /mnt snapper --no-dbus -c root create -d "Fresh install" || warn "Could not create initial snapshot"

# Sync snapshots to limine boot menu
log "Syncing snapshots to limine..."
arch-chroot /mnt limine-snapper-sync 2>/dev/null || warn "limine-snapper-sync had issues (may need to run after first boot)"

log "Snapper configured with bootable snapshots"

# Add Windows Boot Manager entry to limine.conf.
# This MUST happen after every tool that auto-rewrites limine.conf:
#   - limine-update / limine-mkinitcpio-hook (regenerates kernel entries)
#   - limine-snapper-sync (regenerates snapshot entries)
# Both wipe unrecognised entries. Appending here is the only place the
# entry survives to first boot. limine-entry-tool --add-efi only supports
# entries on the same ESP, so we hand-write the entry to chainload the
# Windows ESP.
#
# IMPORTANT: reference the partition by its GPT PARTUUID via guid(), NOT the
# FAT filesystem serial via uuid(). Limine's guid()/uuid() resolves GPT
# partition GUIDs; it does NOT match FAT32 volume serials (e.g. uuid(XXXX-XXXX)),
# which panics at boot with "Failed to open image". lsblk -no PARTUUID gives the
# GPT GUID we want.
log "Looking for a Windows ESP on $DRIVE..."
WIN_ESP_PARTUUID=""
WIN_ESP_PART=""
for p in $(lsblk -ln -o NAME "$DRIVE" | tail -n +2); do
    PART="/dev/$p"
    [[ "$PART" == "$EFI_PART" ]] && continue
    [[ "$(lsblk -no FSTYPE "$PART" 2>/dev/null)" != "vfat" ]] && continue
    TMPMNT=$(mktemp -d)
    if mount -o ro "$PART" "$TMPMNT" 2>/dev/null; then
        if [[ -f "$TMPMNT/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
            WIN_ESP_PARTUUID=$(lsblk -no PARTUUID "$PART")
            WIN_ESP_PART="$PART"
            log "Found Windows ESP: $PART (PARTUUID=$WIN_ESP_PARTUUID)"
        fi
        umount "$TMPMNT"
    fi
    rmdir "$TMPMNT"
    [[ -n "$WIN_ESP_PARTUUID" ]] && break
done

if [[ -n "$WIN_ESP_PARTUUID" ]]; then
    # bootmgfw spoof. Many consumer firmwares (confirmed on AMI-based mini-PCs)
    # ignore the efibootmgr BootOrder lock entirely and always boot
    # \EFI\Microsoft\Boot\bootmgfw.efi, landing straight in Windows and never
    # showing Limine. To guarantee "Limine first, no F12" we replace bootmgfw.efi
    # with Limine and stash the genuine Windows loader as bootmgfwbackup.efi,
    # which the Windows menu entry chainloads.
    #
    # CAVEAT: a Windows *feature* update can reinstall bootmgfw.efi, overwriting
    # Limine and reverting to straight-to-Windows. Re-run option 1 (or just the
    # spoof) to restore it.
    log "Applying bootmgfw spoof (firmware-proof Limine-first boot)..."
    SPOOF_OK=0
    SPOOFMNT=$(mktemp -d)
    if mount "$WIN_ESP_PART" "$SPOOFMNT" 2>/dev/null; then
        WINBOOT="$SPOOFMNT/EFI/Microsoft/Boot"
        LIMINE_EFI="/mnt/boot/EFI/BOOT/BOOTX64.EFI"
        if [[ -f "$WINBOOT/bootmgfw.efi" && -f "$LIMINE_EFI" ]]; then
            # Back up the genuine Windows loader only once — never clobber a real
            # backup with Limine on a re-run.
            if [[ ! -f "$WINBOOT/bootmgfwbackup.efi" ]]; then
                cp "$WINBOOT/bootmgfw.efi" "$WINBOOT/bootmgfwbackup.efi" &&
                    log "Backed up Windows loader -> bootmgfwbackup.efi"
            else
                warn "bootmgfwbackup.efi already exists — keeping existing backup"
            fi
            if cp "$LIMINE_EFI" "$WINBOOT/bootmgfw.efi"; then
                sync
                log "Spoof applied: bootmgfw.efi is now Limine"
                SPOOF_OK=1
            else
                warn "Could not copy Limine over bootmgfw.efi — spoof skipped"
            fi
        else
            warn "bootmgfw.efi or Limine EFI missing — spoof skipped"
        fi
        umount "$SPOOFMNT"
    else
        warn "Could not mount Windows ESP for spoof — skipped"
    fi
    rmdir "$SPOOFMNT"

    # If the spoof succeeded, the Windows menu entry must chainload the
    # backed-up real loader (bootmgfw.efi is now Limine — chainloading it would
    # loop). If it didn't, fall back to the original bootmgfw.efi.
    if [[ "$SPOOF_OK" == "1" ]]; then
        WIN_LOADER="bootmgfwbackup.efi"
    else
        WIN_LOADER="bootmgfw.efi"
    fi

    # Reference the Windows ESP by GPT PARTUUID via guid(), NOT the FAT serial
    # via uuid() — Limine resolves GPT GUIDs, not FAT32 volume serials.
    log "Adding Windows entry to limine.conf (chainloading $WIN_LOADER)"
    cat >> /mnt/boot/limine.conf <<WINENTRY

/Windows Boot Manager
    comment: Chainload the genuine Windows bootloader from the Windows ESP
    protocol: efi_chainload
    image_path: guid($WIN_ESP_PARTUUID):/EFI/Microsoft/Boot/$WIN_LOADER
WINENTRY
else
    warn "No Windows ESP detected — Limine menu will not include a Windows entry"
fi

# Configure SDDM auto-login (Omarchy uses hyprland-uwsm session)
log "Configuring auto-login for $OMARCHY_USER..."
mkdir -p /mnt/etc/sddm.conf.d
cat > /mnt/etc/sddm.conf.d/autologin.conf << SDDMCONF
[Autologin]
User=$OMARCHY_USER
Session=hyprland-uwsm
[Theme]
Current=breeze
SDDMCONF

# Create UEFI boot entry
log "Creating UEFI boot entry..."
DRIVE=$(cat /tmp/install_drive)
EFI_PART=$(cat /tmp/efi_part)
EFI_PART_NUM=$(echo "$EFI_PART" | grep -oE '[0-9]+$')

# Remove any existing Omarchy or Limine entries to avoid duplicates
for entry in $(efibootmgr 2>/dev/null | grep -iE "Omarchy|Limine" | sed -n 's/^Boot\([0-9A-Fa-f]*\).*/\1/p'); do
    log "Removing old boot entry: $entry"
    efibootmgr -b "$entry" -B >/dev/null 2>&1 || true
done

# Create single Omarchy entry
efibootmgr --create --disk "$DRIVE" --part "$EFI_PART_NUM" \
    --loader '\\EFI\\BOOT\\BOOTX64.EFI' --label 'Omarchy' >/dev/null 2>&1 || \
    warn "Could not create UEFI entry - use F12 boot menu"

# Force Limine to the top of BootOrder so firmware lands on Limine first on
# well-behaved firmware. NOTE: this is best-effort only — many consumer
# firmwares ignore BootOrder and always boot bootmgfw.efi, which is why the
# bootmgfw spoof above is the real guarantee. The Windows menu entry is added
# by us explicitly (FIND_BOOTLOADERS does NOT detect Windows — it only scans
# for systemd-boot/rEFInd/EFI-fallback on the same ESP).
log "Locking BootOrder so Limine is the default bootloader..."
NEW_ID=$(efibootmgr 2>/dev/null | grep -i "Omarchy" | head -1 | sed -n 's/^Boot\([0-9A-Fa-f]*\)\*\?.*/\1/p')
BOOTORDER_LOCKED=0
if [[ -n "$NEW_ID" ]]; then
    CURRENT=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: //p')
    if [[ -n "$CURRENT" ]]; then
        REST=$(echo "$CURRENT" | tr ',' '\n' | grep -v "^${NEW_ID}$" | paste -sd, -)
        if [[ -n "$REST" ]]; then
            if efibootmgr -o "${NEW_ID},${REST}" >/dev/null 2>&1; then
                log "BootOrder set: ${NEW_ID} (Omarchy) first, then ${REST}"
                BOOTORDER_LOCKED=1
            else
                warn "Could not set BootOrder - firmware may still default to Windows"
            fi
        else
            efibootmgr -o "${NEW_ID}" >/dev/null 2>&1 && BOOTORDER_LOCKED=1
        fi
    else
        warn "No existing BootOrder found - firmware may auto-rebuild it"
    fi
else
    warn "New Omarchy entry not visible to efibootmgr - cannot lock BootOrder"
fi

# Verify the change actually stuck — some buggy firmware (notably Insyde
# on Acer) silently ignores efibootmgr -o and rebuilds BootOrder pointing
# at Windows. If verification fails, surface it loudly so the user knows
# they may need approach #3 (bootmgfw spoof) rather than discovering it
# on first reboot.
if [[ "$BOOTORDER_LOCKED" == "1" && -n "$NEW_ID" ]]; then
    sleep 1
    VERIFY=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: //p' | cut -d, -f1)
    if [[ "$VERIFY" == "$NEW_ID" ]]; then
        log "BootOrder verified — Limine is first (${VERIFY})"
    else
        warn "BootOrder did NOT stick! Firmware reset it to: ${VERIFY:-<empty>}"
        echo ""
        echo "  Your firmware (likely Insyde / Acer / HP) is ignoring efibootmgr."
        echo "  After first boot, if the machine goes straight to Windows:"
        echo "    1. Use the firmware boot menu (F12/F8/Esc) once to pick Omarchy"
        echo "    2. Inside Omarchy, consider the 'bootmgfw spoof' workaround"
        echo "       (install Limine at \\EFI\\Microsoft\\Boot\\bootmgfw.efi)"
        echo ""
    fi
fi

#===============================================================================
# CLEANUP
#===============================================================================

header "CLEANING UP"

umount /mnt/var/cache/omarchy/mirror/offline 2>/dev/null || true
umount /mnt/opt/packages 2>/dev/null || true

# Recursive unmount of /mnt. If something inside is still busy (lingering
# chroot pid, snapshot mount, etc), fall back to a lazy unmount so we still
# reach the success banner — the kernel will release the mount once the
# holder exits, and the user is about to reboot anyway.
if ! umount -R /mnt 2>/dev/null; then
    warn "/mnt busy — attempting lazy unmount"
    fuser -km /mnt 2>/dev/null || true
    sleep 1
    umount -R -l /mnt 2>/dev/null || warn "Could not fully unmount /mnt — reboot will clear"
fi
cryptsetup close cryptroot 2>/dev/null || warn "cryptsetup close deferred until reboot"

rm -f /tmp/luks_uuid /tmp/efi_part /tmp/root_part /tmp/install_drive /tmp/kernel_name

#===============================================================================
# DONE
#===============================================================================

header "INSTALLATION COMPLETE!"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}║   Omarchy has been installed alongside Windows!              ║${NC}"
echo -e "${GREEN}║                                                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "To boot:"
echo "  1. Reboot your computer"
echo "  2. Press F12/F8/DEL at startup for boot menu"
echo "  3. Select 'Omarchy' for Linux"
echo "  4. Select 'Windows Boot Manager' for Windows"
echo ""
echo "  Username: $OMARCHY_USER"
echo ""
read -p "Press Enter to reboot..." _
reboot
DUALBOOT_SCRIPT

chmod +x "$WORK_DIR/extracted/root/dualboot-setup.sh"

#===============================================================================
# MODIFY BOOT SEQUENCE
#===============================================================================

log "Configuring boot sequence..."

# Backup original automated script
if [[ -f "$WORK_DIR/extracted/root/.automated_script.sh" ]]; then
    mv "$WORK_DIR/extracted/root/.automated_script.sh" "$WORK_DIR/extracted/root/.automated_script.sh.orig"
fi

# Replace .zlogin to run our dual-boot setup
# When a serial port exists (e.g. running under QEMU with -serial), tee the
# installer's full stdout+stderr to it so the host can capture a forensic log
# of the install run without scraping the QEMU window.
cat > "$WORK_DIR/extracted/root/.zlogin" << 'EOF'
# Omarchy Dual-Boot Installer
if [[ $(tty) == "/dev/tty1" ]]; then
    if [[ -w /dev/ttyS0 ]]; then
        /root/dualboot-setup.sh 2>&1 | tee /dev/ttyS0
    else
        /root/dualboot-setup.sh
    fi
fi
EOF

log "Boot sequence configured"

#===============================================================================
# REPACK SQUASHFS
#===============================================================================

log "Repacking squashfs (this takes several minutes)..."
rm "$SQUASHFS"
mksquashfs "$WORK_DIR/extracted" "$SQUASHFS" -comp zstd -Xcompression-level 3

if [[ ! -f "$SQUASHFS" ]]; then
    error "Failed to create squashfs!"
fi
log "New squashfs created: $(du -h "$SQUASHFS" | cut -f1)"

#===============================================================================
# UPDATE AIROOTFS CHECKSUM
#===============================================================================

# Recompute the airootfs.sha512 to match the new squashfs. archiso checks
# this only when the kernel cmdline includes verify=y (3.6 doesn't), but
# keeping it in sync is cheap insurance against future versions enabling it.
log "Updating airootfs.sha512..."
NEW_HASH=$(sha512sum "$SQUASHFS" | awk '{print $1}')
echo "$NEW_HASH  airootfs.sfs" > "$WORK_DIR/newiso/arch/x86_64/airootfs.sha512"

#===============================================================================
# CREATE ISO (faithful boot-layout replay)
#===============================================================================
# Replay the original ISO's boot setup byte-for-byte and overlay only the
# files we changed (patched squashfs + its checksum). This preserves MBR,
# GPT, El Torito, the appended EFI partition, archisosearchuuid, and the
# archiso layout flags (--mbr-force-bootable, -partition_offset 16,
# -iso_mbr_part_type 0x00, -partition_cyl_align off) that mkarchiso emits.
# Recreating from scratch via -as mkisofs tends to drop those and breaks
# boot on stricter UEFI firmware (Acer Insyde, Lenovo, MSI). Works for any
# Omarchy/archiso version (3.4, 3.5, 3.6, future) without per-version tweaks.

log "Building new ISO via boot-image replay..."
rm -f "$OUTPUT_ISO"

xorriso \
    -indev "$SOURCE_ISO" \
    -outdev "$OUTPUT_ISO" \
    -boot_image any replay \
    -map "$SQUASHFS" /arch/x86_64/airootfs.sfs \
    -map "$WORK_DIR/newiso/arch/x86_64/airootfs.sha512" /arch/x86_64/airootfs.sha512 \
    -commit

#===============================================================================
# DONE
#===============================================================================

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  SUCCESS!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Created: $OUTPUT_ISO"
echo "  Size:    $(du -h "$OUTPUT_ISO" | cut -f1)"
echo ""
echo "  This ISO provides:"
echo "    • Option 1: Dual-boot install (preserves Windows)"
echo "    • Option 3: Standard install (original Omarchy installer)"
echo ""
echo "  Next steps:"
echo "    1. Copy ISO to Ventoy USB drive"
echo "    2. Boot from Ventoy"
echo "    3. Select option 1 for dual-boot"
echo ""
