#!/bin/bash
set -Eeuo pipefail

LOG="/root/gentoo-install-part2-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

CONF="/root/gentoo-installer.conf"
die(){ echo "[FATAL] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -f /etc/gentoo-release ]] || die "This does not appear to be an installed Gentoo system."
[[ -f "$CONF" ]] || die "Missing $CONF."
[[ -d /proc ]] || die "/proc is not mounted."
mountpoint -q /sys || die "/sys is not mounted."
mountpoint -q /dev || die "/dev is not mounted."

source "$CONF"

echo
echo "=============================================="
echo " Gentoo automated installer — PART 2"
echo " Profile: $PROFILE"
echo " Init:    $INIT"
echo " GPU:     ${GPU_VENDOR:-Other}"
echo "=============================================="
echo

# Choose one login manager. Defaults match the selected desktop profile.
if [[ "$PROFILE" == gentoo_kde ]]; then
    DEFAULT_DM=2
else
    DEFAULT_DM=1
fi
echo "Choose a login manager:"
echo "  1) Ly (TUI)"
echo "  2) SDDM (graphical)"
echo "  3) greetd + tuigreet (TUI)"
while true; do
    read -r -p "Selection [$DEFAULT_DM]: " DM_REPLY || DM_REPLY=""
    DM_REPLY="${DM_REPLY:-$DEFAULT_DM}"
    case "$DM_REPLY" in
        1) LOGIN_MANAGER="ly"; break ;;
        2) LOGIN_MANAGER="sddm"; break ;;
        3) LOGIN_MANAGER="greetd"; break ;;
        *) echo "Choose 1, 2 or 3." ;;
    esac
done
echo "Selected login manager: $LOGIN_MANAGER"

THREADS="$(nproc)"
RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
JOBS="$THREADS"
if (( RAM_MB < 4096 )); then
    JOBS=2
elif (( RAM_MB < 8192 && THREADS > 4 )); then
    JOBS=$(( (THREADS + 1) / 2 ))
fi
(( JOBS < 1 )) && JOBS=1

mkdir -p     /etc/portage/package.use     /etc/portage/package.accept_keywords     /etc/portage/package.unmask     /etc/portage/package.mask     /etc/portage/repos.conf     /etc/portage/binrepos.conf

# Arch-like package availability mode:
# ignore package.mask and allow stable + unstable (~amd64) ebuilds.
# Hard -amd64 masks and dependency/USE conflicts can still block a package.
cat > /etc/portage/package.unmask/99-installer-unmask-all <<'EOF'
*/*
EOF

cat > /etc/portage/package.accept_keywords/99-installer-unstable-all <<'EOF'
*/* ~amd64
EOF

# Hardware-independent Portage settings.
# Portage supports /etc/portage/make.conf as a directory; fragments are read
# in lexical order and merged into the final configuration.
if [[ -f /etc/portage/make.conf ]]; then
    cp -a /etc/portage/make.conf /etc/portage/make.conf.gentoo-installer.bak
    rm -f /etc/portage/make.conf
fi
mkdir -p /etc/portage/make.conf
cat > /etc/portage/make.conf/00-installer <<EOF
# Gentoo installer settings. Existing Stage 3 make.conf is preserved.
MAKEOPTS="-j${JOBS}"
GRUB_PLATFORMS="efi-64"
FEATURES="${FEATURES-} getbinpkg binpkg-request-signature"
EOF

# Configure VIDEO_CARDS according to the selection made in part 1.
# AMD uses the open-source kernel driver (amdgpu) plus Mesa (radeonsi).
rm -f /etc/portage/package.use/00-video_cards /etc/portage/package.use/10-nvidia
case "${GPU_VENDOR:-Other}" in
    NVIDIA)
        cat > /etc/portage/package.use/00-video_cards <<'EOF'
*/* VIDEO_CARDS: -* nvidia
EOF
        cat > /etc/portage/package.use/10-nvidia <<'EOF'
x11-drivers/nvidia-drivers X wayland dist-kernel
EOF
        ;;
    AMD)
        cat > /etc/portage/package.use/00-video_cards <<'EOF'
*/* VIDEO_CARDS: -* amdgpu radeonsi
EOF
        ;;
    Intel)
        cat > /etc/portage/package.use/00-video_cards <<'EOF'
*/* VIDEO_CARDS: -* intel
EOF
        ;;
    Other)
        # Keep the Stage 3/profile defaults for unknown or virtual GPUs.
        ;;
    *)
        die "Unknown GPU vendor in installer config: $GPU_VENDOR"
        ;;
esac

# Common desktop stack.
cat > /etc/portage/package.use/20-desktop-installer <<'EOF'
media-video/pipewire dbus sound-server pipewire-alsa pipewire-pulse bluetooth
media-video/wireplumber elogind
sys-apps/xdg-desktop-portal wayland
x11-base/xwayland libei
media-libs/mesa vulkan wayland
gui-apps/waybar wayland
EOF

# Profile: use the current 23.0 desktop profile, keeping the selected init.
emerge --sync

if [[ "$INIT" == systemd ]]; then
    cat > /etc/portage/package.use/05-init <<'EOF'
sys-apps/dbus systemd
media-video/pipewire systemd
media-video/wireplumber systemd
EOF
else
    cat > /etc/portage/package.use/05-init <<'EOF'
sys-apps/dbus elogind
media-video/pipewire elogind
media-video/wireplumber elogind
EOF
fi

case "$PROFILE" in
    gentoo_kde)
        if [[ "$LOGIN_MANAGER" == sddm ]]; then
            cat > /etc/portage/package.use/30-plasma <<'EOF'
kde-plasma/plasma-meta sddm display-manager networkmanager
EOF
        else
            cat > /etc/portage/package.use/30-plasma <<'EOF'
kde-plasma/plasma-meta display-manager networkmanager
EOF
        fi
        ;;
    gentoo_niri)
        cat > /etc/portage/package.use/30-niri <<'EOF'
gui-apps/waybar niri
EOF
        ;;
    gentoo_hyprland)
        cat > /etc/portage/package.use/30-hyprland <<'EOF'
gui-apps/waybar
EOF
        ;;
esac

if command -v eselect >/dev/null 2>&1; then
    if [[ "$PROFILE" == gentoo_kde ]]; then
        if [[ "$INIT" == systemd ]]; then
            PROFILE_TARGET="default/linux/amd64/23.0/desktop/plasma/systemd"
        else
            PROFILE_TARGET="default/linux/amd64/23.0/desktop/plasma"
        fi
    elif [[ "$INIT" == systemd ]]; then
        PROFILE_TARGET="default/linux/amd64/23.0/desktop/systemd"
    else
        PROFILE_TARGET="default/linux/amd64/23.0/desktop"
    fi
    if eselect profile list | grep -q "$PROFILE_TARGET"; then
        eselect profile set "$PROFILE_TARGET"
    else
        echo "[WARN] Profile not found $PROFILE_TARGET; keeping the Stage 3 profile."
    fi
fi

echo
echo "Installing eselect-repository..."
emerge --ask=n --verbose --getbinpkg     --autounmask=y --autounmask-write=y --autounmask-unrestricted-atoms=y     --backtrack=30 app-eselect/eselect-repository

# Official alternate repositories.
eselect repository enable guru
emaint sync -r guru

if [[ "$PROFILE" == gentoo_hyprland ]]; then
    eselect repository enable hyproverlay
    emaint sync -r hyproverlay
    cat > /etc/portage/package.accept_keywords/hyproverlay <<'EOF'
*/*::hyproverlay
EOF
fi

# Apply any config changes generated by Portage before emerging packages.
etc-update --automode -5 || true

portage_emerge() {
    local tries=1
    local max=4
    local -a args=("$@")
    while (( tries <= max )); do
        echo
        echo ">>> emerge attempt $tries/$max: ${args[*]}"
        if emerge --ask=n --verbose             --autounmask=y             --autounmask-write=y             --autounmask-unrestricted-atoms=y             --backtrack=30             --with-bdeps=y             --getbinpkg             "${args[@]}"; then
            return 0
        fi
        echo "[WARN] emerge failed; applying generated Portage config and retrying..."
        etc-update --automode -5 || true
        ((tries++))
    done
    return 1
}

echo
echo "Installing base tools..."
portage_emerge     app-admin/sudo     app-editors/vim     app-editors/nano     dev-vcs/git     net-misc/curl     net-misc/wget     net-misc/rsync     sys-process/btop     sys-apps/man-pages     sys-apps/pciutils     sys-apps/usbutils     net-misc/openssh     net-misc/networkmanager     sys-apps/dbus     sys-auth/polkit     sys-auth/seatd     media-video/pipewire     media-video/wireplumber     media-libs/mesa     media-libs/libglvnd     media-libs/vulkan-loader     dev-libs/wayland     dev-libs/wayland-protocols     dev-libs/libinput     app-misc/wayland-utils     x11-base/xwayland     x11-base/xorg-proto     x11-libs/libX11     x11-libs/libXext     x11-libs/libXrandr     x11-libs/libXrender     x11-libs/libXi     x11-libs/libXfixes     sys-apps/xdg-desktop-portal     app-shells/bash-completion

echo
case "${GPU_VENDOR:-Other}" in
    NVIDIA)
        echo "Installing proprietary NVIDIA driver..."
        portage_emerge x11-drivers/nvidia-drivers
        ;;
    AMD)
        echo "Using the in-kernel AMDGPU/Radeon driver with Mesa; installing firmware..."
        # AMD's kernel driver is provided by Linux; Mesa supplies OpenGL/Vulkan userspace.
        portage_emerge sys-kernel/linux-firmware
        ;;
    Intel)
        echo "Using the in-kernel Intel graphics driver with Mesa; installing firmware..."
        portage_emerge sys-kernel/linux-firmware
        ;;
    Other)
        echo "Keeping the default graphics driver stack; installing firmware..."
        portage_emerge sys-kernel/linux-firmware
        ;;
esac
portage_emerge net-wireless/bluez

# Configure hostname for both systemd and OpenRC.
echo
echo "=== HOSTNAME ==="
read -r -p "Enter hostname (default: gentoo): " HOSTNAME
HOSTNAME="${HOSTNAME:-gentoo}"
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "Invalid hostname. Use letters, numbers and internal hyphens; maximum 63 characters."
printf '%s\n' "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost $HOSTNAME
::1         localhost $HOSTNAME
EOF
if [[ "$INIT" == systemd ]]; then
    hostnamectl set-hostname "$HOSTNAME" || true
else
    mkdir -p /etc/conf.d
    printf 'hostname="%s"\n' "$HOSTNAME" > /etc/conf.d/hostname
fi

# User setup first, so final system has a usable account.
echo
echo "=== ROOT PASSWORD ==="
passwd root

read -r -p "New username: " USERNAME
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username."
id "$USERNAME" >/dev/null 2>&1 && die "User already exists."

for g in wheel video audio render input; do
    getent group "$g" >/dev/null || groupadd "$g"
done
getent group seat >/dev/null && EXTRA_GROUPS=",seat" || EXTRA_GROUPS=""
useradd -m -s /bin/bash -G "wheel,video,audio,render,input${EXTRA_GROUPS}" "$USERNAME"

echo "Password for user $USERNAME:"
passwd "$USERNAME"

install -d -m 0750 /etc/sudoers.d
cat > /etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 0440 /etc/sudoers.d/10-wheel
visudo -c

# Kernel: source gentoo-kernel, never gentoo-kernel-bin.
echo
echo "Installing gentoo-kernel (local build)..."
portage_emerge --usepkg=n --buildpkg=n sys-kernel/gentoo-kernel

# Init/system services.
if [[ "$INIT" == systemd ]]; then
    echo
    echo "Configuring systemd..."
    systemd-machine-id-setup || true
    systemctl preset-all --preset-mode=enable-only || true
    systemctl enable NetworkManager.service || true
    systemctl enable sshd.service || true
    systemctl enable bluetooth.service || true
else
    echo
    echo "Configuring OpenRC..."
    rc-update add dbus default || true
    rc-update add NetworkManager default || true
    rc-update add sshd default || true
    rc-update add bluetooth default || true
    rc-update add elogind boot || true
fi

# Ly and Niri are in GURU; Hyprland additionally gets hyproverlay.
# GURU is enabled for all profiles so optional compositor packages can be
# installed consistently when selected.
# Ly currently lives in GURU and may require a keyword generated by autounmask.
# Global ~amd64 is intentionally enabled by this installer.
#
# Ly is installed only for compositor-specific profiles.
case "$PROFILE" in
    gentoo_base)
        ;;
    gentoo_niri)
        portage_emerge gui-wm/niri::guru gui-apps/waybar gui-apps/fuzzel gui-apps/mako gui-apps/swaybg gui-apps/swayidle gui-apps/swaylock
        ;;
    gentoo_hyprland)
        portage_emerge gui-wm/hyprland gui-apps/waybar gui-libs/xdg-desktop-portal-hyprland gui-apps/hyprlock gui-apps/hypridle gui-apps/hyprpaper gui-apps/hyprpicker
        ;;
    gentoo_kde)
        portage_emerge kde-plasma/plasma-meta kde-apps/dolphin kde-apps/konsole x11-base/xorg-server
        ;;
esac

# Install and enable the chosen login manager.
case "$LOGIN_MANAGER" in
    ly)
        portage_emerge x11-misc/ly::guru
        if [[ "$INIT" == systemd ]]; then
            systemctl enable ly.service || echo "[WARN] Enable ly.service manually if needed."
        elif [[ -x /etc/init.d/ly ]]; then
            rc-update add ly default || echo "[WARN] Could not enable Ly in OpenRC."
        else
            echo "[WARN] Ly OpenRC init script not found; enable it manually if available."
        fi
        ;;
    sddm)
        portage_emerge kde-plasma/sddm
        if [[ "$INIT" == systemd ]]; then
            systemctl enable sddm.service || echo "[WARN] Enable sddm.service manually if needed."
        else
            portage_emerge gui-libs/display-manager-init
            cat > /etc/conf.d/display-manager <<'EOF'
CHECKVT=7
DISPLAYMANAGER="sddm"
EOF
            rc-update add display-manager default || echo "[WARN] Could not enable display-manager in OpenRC."
        fi
        ;;
    greetd)
        portage_emerge gui-libs/greetd gui-apps/tuigreet
        install -d -m 0755 /etc/greetd
        cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session"
user = "greeter"
EOF
        if [[ "$INIT" == systemd ]]; then
            systemctl enable greetd.service || echo "[WARN] greetd.service not found; enable it manually."
        elif [[ -x /etc/init.d/greetd ]]; then
            rc-update add greetd default || echo "[WARN] Could not enable greetd in OpenRC."
        else
            echo "[WARN] greetd OpenRC init script not found; enable it manually if available."
        fi
        ;;
esac

# Locale/time. Keep timezone neutral for a shareable installer.
if [[ -f /etc/locale.gen ]]; then
    sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
    locale-gen || true
fi
printf 'LANG="en_US.UTF-8"\n' > /etc/env.d/02locale
env-update

# Sanity checks before the final world rebuild.
echo
echo "Checking selected profile and repositories..."
eselect profile show || true
eselect repository list || true

# Final world rebuild after all USE/profile/repository changes.
echo
echo "Final @world rebuild..."
portage_emerge @world

echo
echo "Installing GRUB..."
portage_emerge sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo --recheck
grub-mkconfig -o /boot/grub/grub.cfg

cat > /root/gentoo-install-summary.txt <<EOF
Gentoo installer summary
========================
Hostname: $HOSTNAME
Profile : $PROFILE
Init    : $INIT
Login manager: $LOGIN_MANAGER
User    : $USERNAME
CPU     : $THREADS threads
RAM     : ${RAM_MB} MiB
MAKEOPTS: -j$JOBS
Root    : $ROOT
EFI     : $EFI
Swap    : $SWAP

Repositories:
- gentoo
- guru
$( [[ "$PROFILE" == gentoo_hyprland ]] && echo "- hyproverlay" )

Important:
- GPU vendor: ${GPU_VENDOR:-Other}.
- GPU-specific VIDEO_CARDS flags are configured in package.use/00-video_cards when applicable.
- NVIDIA uses x11-drivers/nvidia-drivers; AMD uses the in-kernel AMDGPU/Radeon driver and Mesa; Intel uses the in-kernel driver and Mesa.
- x11-base/xwayland is installed for every profile.
- sys-kernel/gentoo-kernel is used, not gentoo-kernel-bin.
EOF

cp "$LOG" /root/gentoo-install-part2-final.log || true

echo
echo "=============================================="
echo " DONE."
echo "=============================================="
echo "The installation is complete."
echo
echo "Before reboot, you can check:"
echo "  emerge --info"
echo "  eselect profile show"
echo "  eselect repository list"
echo "  emerge -pv @world"
echo
echo "After exiting chroot:"
echo "  exit"
echo "  umount -R /mnt/gentoo"
echo "  reboot"
