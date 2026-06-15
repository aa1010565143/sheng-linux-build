#!/bin/bash
set -e
IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
FEDORA_VERSION="44" 

DISTRO=$1; KERNEL=$2; DESKTOP_ENV=${3:-gnome}
CUSTOM_USER=${4:-xiaomi}; CUSTOM_PASS=${5:-123456}
BOOT_MODE=${6:-dual}

# 自动解析单双系统
if [ "$BOOT_MODE" = "single" ]; then
    ROOT_PART="userdata"
    IMG_SUFFIX="singleboot"
else
    ROOT_PART="linux"
    IMG_SUFFIX="dualboot"
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ROOTFS_IMG="fedora_desktop_${DESKTOP_ENV}_${IMG_SUFFIX}_${TIMESTAMP}.img"

rm -rf rootdir || true; truncate -s $IMAGE_SIZE "$ROOTFS_IMG"; mkfs.ext4 "$ROOTFS_IMG"
mkdir rootdir; mount -o loop "$ROOTFS_IMG" rootdir

docker pull --platform linux/arm64 fedora:${FEDORA_VERSION}
docker create --name fedora-temp fedora:${FEDORA_VERSION}
docker export fedora-temp | tar -x -C rootdir/; docker rm fedora-temp

mount --bind /dev rootdir/dev; mount --bind /dev/pts rootdir/dev/pts
mount -t proc proc rootdir/proc; mount -t sysfs sys rootdir/sys
echo "nameserver 8.8.8.8" > rootdir/etc/resolv.conf

chroot rootdir dnf -y install git gcc make kernel-headers
chroot rootdir dnf -y update --exclude=kernel-core

# ✅ 这里提前安装好 Fedora 原生的依赖包 (glib2, libyaml, alsa-ucm 等)
chroot rootdir dnf -y install --exclude=kernel-core \
    systemd sudo vim wget curl tar xz pciutils findutils \
    NetworkManager wpa_supplicant dialog qrtr openssh-server \
    glib2 libgudev polkit-libs libyaml protobuf-c libqmi alsa-ucm

if [ "$DESKTOP_ENV" = "gnome" ]; then
    chroot rootdir dnf -y install @gnome-desktop --exclude=kernel-core
    chroot rootdir dnf -y install gdm
    mkdir -p rootdir/etc/gdm
    printf "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$CUSTOM_USER\n" > rootdir/etc/gdm/custom.conf
    chroot rootdir systemctl enable gdm
elif [ "$DESKTOP_ENV" = "kde" ]; then
    chroot rootdir dnf -y install @kde-desktop --exclude=kernel-core
    chroot rootdir dnf -y install sddm
    mkdir -p rootdir/etc/sddm.conf.d
    printf "[Autologin]\nUser=$CUSTOM_USER\nSession=plasma\n" > rootdir/etc/sddm.conf.d/autologin.conf
    chroot rootdir systemctl enable sddm
elif [ "$DESKTOP_ENV" = "xfce" ]; then
    chroot rootdir dnf -y install @xfce-desktop-environment lightdm --exclude=kernel-core
    mkdir -p rootdir/etc/lightdm/lightdm.conf.d
    printf "[Seat:*]\nautologin-user=$CUSTOM_USER\nautologin-user-timeout=0\n" > rootdir/etc/lightdm/lightdm.conf.d/autologin.conf
    chroot rootdir systemctl enable lightdm
fi

# ✅ 使用 dnf 本地无视依赖检查安全安装纯净 RPM 包
if ls *.rpm 1> /dev/null 2>&1; then
    cp *.rpm rootdir/tmp/
    # 使用 --setopt=strict=0 确保就算遇到小警告也不卡死流程
    chroot rootdir bash -c "dnf -y --setopt=strict=0 install /tmp/*.rpm || true"
    chroot rootdir rm -f /tmp/*.rpm
    KERNEL_MODULE_DIR=$(ls -1t rootdir/usr/lib/modules/ | head -n 1)
    if [ -n "$KERNEL_MODULE_DIR" ]; then
        chroot rootdir /usr/sbin/depmod -a "$KERNEL_MODULE_DIR" || true
        chroot rootdir dnf -y install dracut
        chroot rootdir dracut -N --kver "$KERNEL_MODULE_DIR" --force "/boot/initramfs-linux.img"
        [ -f "rootdir/boot/vmlinuz-$KERNEL_MODULE_DIR" ] && cp "rootdir/boot/vmlinuz-$KERNEL_MODULE_DIR" "rootdir/boot/Image"
    fi
fi

chroot rootdir bash -c "echo 'root:$CUSTOM_PASS' | chpasswd"
chroot rootdir useradd -m -s /bin/bash "$CUSTOM_USER"
chroot rootdir bash -c "echo '$CUSTOM_USER:$CUSTOM_PASS' | chpasswd"
chroot rootdir usermod -aG wheel,audio,video,input "$CUSTOM_USER"
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > rootdir/etc/sudoers.d/wheel
chmod 440 rootdir/etc/sudoers.d/wheel

mkdir -p rootdir/etc/selinux
echo "SELINUX=disabled" > rootdir/etc/selinux/config

# ✅ 修正服务名为 qrtr-ns，并添加 || true 保护
chroot rootdir systemctl enable NetworkManager qrtr-ns sshd || true
chroot rootdir systemctl set-default graphical.target

# 动态写入单/双系统对应的 fstab
printf "PARTLABEL=%s / ext4 defaults,noatime,errors=remount-ro 0 1\n" "$ROOT_PART" > rootdir/etc/fstab

chroot rootdir dnf clean all
fuser -k -9 -m rootdir || true; sleep 2
umount -l rootdir/dev/pts || true; umount -l rootdir/dev || true; umount -l rootdir/proc || true; umount -l rootdir/sys || true; umount -l rootdir || true
rm -rf rootdir

tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"
img2simg "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"; 7z a "fedora_desktop_${DESKTOP_ENV}_${IMG_SUFFIX}_${TIMESTAMP}.7z" "sparse_${ROOTFS_IMG}"
rm -f "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"
