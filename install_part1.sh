#!/bin/bash
set -Eeuo pipefail

LOG="/tmp/gentoo-install-part1-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

TARGET="/mnt/gentoo"
DIST="https://distfiles.gentoo.org/releases/amd64/autobuilds"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die(){ echo "[FATAL] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Not found: $1"; }
confirm(){
    local prompt="$1" ans
    read -r -p "$prompt [yes/NO]: " ans
    [[ "$ans" == "yes" ]]
}

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -d /sys/firmware/efi ]] || die "The Live ISO was not booted in UEFI mode."

for x in awk curl findmnt lsblk mount umount mkfs.fat mkfs.ext4 mkswap swapoff sfdisk partprobe partx udevadm wipefs blkid tar sha256sum sed grep; do need "$x"; done

cleanup_disk_state() {
    local disk="$1"
    local part target
    echo "Releasing old mount/swap state for $disk..."

    # Unmount every mounted partition belonging to the selected disk.
    while read -r part; do
        [[ -n "$part" ]] || continue
        while read -r target; do
            [[ -n "$target" ]] || continue
            umount "$target" 2>/dev/null || umount -l "$target" 2>/dev/null || true
        done < <(findmnt -rn -S "$part" -o TARGET 2>/dev/null || true)
    done < <(lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part"{print $1}')

    # A previous failed run may have activated the old swap partition.
    while read -r part; do
        [[ -n "$part" ]] || continue
        if grep -qE "^$part " /proc/swaps 2>/dev/null; then
            echo "Disabling old swap: $part"
            swapoff "$part" || true
        fi
    done < <(lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part"{print $1}')

    sync
}

reread_partition_table() {
    local disk="$1"
    echo "Refreshing the kernel partition table..."
    partprobe "$disk" 2>/dev/null || true
    partx -u "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 2
}

echo
echo "=============================================="
echo " Gentoo automated installer — PART 1"
echo " Before chroot: partitioning + Stage 3 + fstab."
echo "=============================================="
echo

lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,FSVER,LABEL,MOUNTPOINTS,MODEL

echo
read -r -p "Installation disk (e.g. /dev/nvme0n1): " DISK
[[ -b "$DISK" ]] || die "Not a block device: $DISK"
[[ "$(lsblk -dn -o TYPE "$DISK")" == "disk" ]] || die "A whole disk is required, not a partition."

echo
echo "Profile:"
select PROFILE in gentoo_base gentoo_niri gentoo_hyprland; do
    [[ -n "${PROFILE:-}" ]] && break
done

echo
echo "Init:"
select INIT in systemd OpenRC; do
    [[ -n "${INIT:-}" ]] && break
done

echo
echo "Partitioning:"
select PARTMODE in automatic cfdisk fdisk parted; do
    [[ -n "${PARTMODE:-}" ]] && break
done

echo
echo "Selected:"
echo "  Disk:    $DISK"
echo "  Profile: $PROFILE"
echo "  Init:    $INIT"
echo "  Mode:   $PARTMODE"
echo

if [[ "$PARTMODE" == automatic ]]; then
    echo
    read -r -p "Swap size (e.g. 16G or 8G): " SWAP_SIZE
    SWAP_SIZE="${SWAP_SIZE// /}"
    [[ "$SWAP_SIZE" =~ ^[1-9][0-9]*[MG]$ ]] || die "Invalid swap size. Use a format such as 8G or 16G."

    confirm "WARNING: $DISK will be COMPLETELY ERASED." || die "Cancelled."

    cleanup_disk_state "$DISK"
    umount -R "$TARGET" 2>/dev/null || true
    mkdir -p "$TARGET"

    wipefs -af "$DISK"
    sfdisk --delete "$DISK" 2>/dev/null || true
    sync

    sfdisk "$DISK" <<EOF
label: gpt
,1G,U
,$SWAP_SIZE,S
,,L
EOF
    reread_partition_table "$DISK"

    mapfile -t PARTS < <(lsblk -nrpo NAME,TYPE "$DISK" | awk '$2=="part"{print $1}')
    [[ ${#PARTS[@]} -ge 3 ]] || die "Could not determine EFI, swap and root."
    EFI="${PARTS[0]}"
    SWAP="${PARTS[1]}"
    ROOT="${PARTS[2]}"

    echo "Automatic:"
    echo "  EFI : $EFI  (1 GiB)"
    if [[ "$SWAP_SIZE" == NONE ]]; then
        echo "  swap: disabled"
    else
        echo "  swap: $SWAP ($SWAP_SIZE)"
    fi
    echo "  root: $ROOT (remaining space)"
else
    echo
    cleanup_disk_state "$DISK"
    echo "Starting $PARTMODE. Create the GPT/UEFI partition layout manually."
    echo "After exiting $PARTMODE, the script will reread the partition table."
    case "$PARTMODE" in
        cfdisk) cfdisk "$DISK" ;;
        fdisk)  fdisk "$DISK" ;;
        parted) parted "$DISK" ;;
    esac

    reread_partition_table "$DISK"

    echo
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$DISK"
    echo

    read -r -p "EFI partition (e.g. /dev/nvme0n1p1): " EFI
    read -r -p "ROOT partition (e.g. /dev/nvme0n1p2): " ROOT
    read -r -p "SWAP partition (Enter = no swap): " SWAP

    [[ -b "$EFI" ]] || die "EFI partition not found."
    [[ -b "$ROOT" ]] || die "ROOT partition not found."
    [[ -z "$SWAP" || -b "$SWAP" ]] || die "SWAP partition not found."

    confirm "The following will be formatted: EFI=$EFI and ROOT=$ROOT. Continue?" || die "Cancelled."
fi

echo
echo "Formatting:"
echo "  EFI : $EFI -> FAT32"
echo "  ROOT: $ROOT -> ext4"
[[ -n "$SWAP" ]] && echo "  SWAP: $SWAP -> swap"
confirm "Confirm formatting?" || die "Cancelled."

mkfs.fat -F 32 "$EFI"
mkfs.ext4 -F "$ROOT"
if [[ -n "$SWAP" ]]; then
    mkswap "$SWAP"
    swapon "$SWAP"
fi

mkdir -p "$TARGET"
mount "$ROOT" "$TARGET"
mkdir -p "$TARGET/efi"
mount "$EFI" "$TARGET/efi"

mkdir -p "$TARGET/var/cache/binpkgs" "$TARGET/etc/portage/repos.conf" "$TARGET/etc/portage/binrepos.conf"

case "$INIT" in
    systemd) STAGE_DIR="current-stage3-amd64-systemd"; BIN_PROFILE="23.0/x86-64" ;;
    OpenRC)  STAGE_DIR="current-stage3-amd64-openrc";  BIN_PROFILE="23.0/x86-64" ;;
esac

META_URL="$DIST/$STAGE_DIR/latest-stage3-amd64-${INIT,,}.txt"
TMPDIR="$(mktemp -d /tmp/gentoo-stage3.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

echo
echo "Downloading the current Stage 3:"
curl -fL --retry 5 --retry-all-errors -o "$TMPDIR/latest.txt" "$META_URL"

STAGE_FILE="$(awk '$1 ~ /^stage3-amd64-.*\.tar\.xz$/ {print $1; exit}' "$TMPDIR/latest.txt")"
[[ -n "$STAGE_FILE" ]] || die "Stage 3 not found in $META_URL"

STAGE_URL="$DIST/$STAGE_DIR/$STAGE_FILE"
SHA_URL="$STAGE_URL.sha256"

curl -fL --retry 5 --retry-all-errors -o "$TMPDIR/$STAGE_FILE" "$STAGE_URL"
curl -fL --retry 5 --retry-all-errors -o "$TMPDIR/$STAGE_FILE.sha256" "$SHA_URL"

cd "$TMPDIR"
echo "Checking SHA256..."
sha256sum -c "$STAGE_FILE.sha256"
echo "SHA256 verification passed."

echo "Extracting Stage 3..."
tar xpf "$TMPDIR/$STAGE_FILE" -C "$TARGET" --xattrs-include='*.*' --numeric-owner

cat > "$TARGET/etc/portage/repos.conf/gentoo.conf" <<'EOF'
[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
sync-webrsync-verify-signature = true
EOF

cat > "$TARGET/etc/portage/binrepos.conf/gentoobinhost.conf" <<EOF
[binhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/${BIN_PROFILE}/
EOF

mkdir -p "$TARGET/etc"
cat > "$TARGET/etc/fstab" <<EOF
# Generated by gentoo installer
UUID=$(blkid -s UUID -o value "$ROOT") / ext4 defaults,noatime 0 1
UUID=$(blkid -s UUID -o value "$EFI") /efi vfat defaults,noatime 0 2
EOF
if [[ "$SWAP" != NONE ]]; then
    echo "UUID=$(blkid -s UUID -o value "$SWAP") none swap sw 0 0" >> "$TARGET/etc/fstab"
fi

cat > "$TARGET/root/gentoo-installer.conf" <<EOF
PROFILE="$PROFILE"
INIT="$INIT"
EFI="$EFI"
ROOT="$ROOT"
SWAP="$SWAP"
STAGE3="$STAGE_FILE"
EOF

[[ -f "$SCRIPT_DIR/install_part2.sh" ]] || die "install_part2.sh must be located next to install_part1.sh."
install -m 0755 "$SCRIPT_DIR/install_part2.sh" "$TARGET/root/install_part2.sh"

if [[ -f /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
fi

cp "$LOG" "$TARGET/root/gentoo-install-part1.log" || true

echo
echo "=============================================="
echo " PART 1 completed."
echo "=============================================="
echo
echo "Now run manually:"
echo
cat <<'EOF'
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --rbind /run /mnt/gentoo/run
mount --make-rslave /mnt/gentoo/run
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/resolv.conf
chroot /mnt/gentoo /bin/bash
source /etc/profile
/root/install_part2.sh
EOF
echo
