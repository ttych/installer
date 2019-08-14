#!/bin/sh

BPOOL="${BPOOL:-bpool}"
RPOOL="${RPOOL:-rpool}"
MNT="${MNT:-/mnt}"
HOSTNAME="${HOSTNAME:-server}"
CODENAME="$(lsb_release -c -s)"

##########

disk_wipe()
{
    [ $# -ne 1 ] && return 1
    mdadm --zero-superblock --force "$1"
    sgdisk --zap-all "$1"
}

disk_format_system() # disk
{
    disk_wipe "$1" &&
        sgdisk -a1 -n1:24K:+1000K -t1:EF02 "$1" &&
        sgdisk     -n2:1M:+512M   -t2:EF00 "$1" &&
        sgdisk     -n3:0:+512M    -t3:BF01 "$1" &&
        sgdisk     -n4:0:0        -t4:BF01 "$1"

    partprobe "$1"
    sleep 1

    for p in 1 2 3 4; do
        [ -e "${1}-part${p}" ] || return 1
    done
}

disk_format_full_zfs()
{
    # FIXME
    :
}

disk_list()
{
    lsblk
    echo
    ls -l /dev/disk/by-id/*
}

zfs_enable()
{
    modprobe zfs
}

zfs_system_create() # disk1 disk2
{
    zfs_enable &&
        zfs_system_create_bpool "$1" "$2" &&
        zfs_system_create_rpool "$1" "$2" &&
        zfs_system_create_rpool_datasets &&
        zfs_system_create_bpool_datasets
}

zfs_system_create_bpool()
{
    zpool create -f \
          -o ashift=12 \
          -d \
          -o feature@async_destroy=enabled \
          -o feature@bookmarks=enabled \
          -o feature@embedded_data=enabled \
          -o feature@empty_bpobj=enabled \
          -o feature@enabled_txg=enabled \
          -o feature@extensible_dataset=enabled \
          -o feature@filesystem_limits=enabled \
          -o feature@hole_birth=enabled \
          -o feature@large_blocks=enabled \
          -o feature@lz4_compress=enabled \
          -o feature@spacemap_histogram=enabled \
          -o feature@userobj_accounting=enabled \
          -O acltype=posixacl \
          -O compression=lz4 \
          -O devices=off \
          -O normalization=formD \
          -O relatime=on \
          -O xattr=sa \
          -O mountpoint=legacy \
          -R $MNT \
          $BPOOL mirror "${1}"-part3 "${2}"-part3
}

zfs_system_create_rpool()
{
    zpool create -f \
          -o ashift=12 \
          -O compression=lz4 \
          -O mountpoint=legacy \
          -O atime=off \
          -R $MNT \
          $RPOOL mirror "${1}"-part4 "${2}"-part4
}

zfs_system_create_rpool_datasets()
{
    zfs create -o acltype=posixacl -o dnodesize=auto -o normalization=formD -o relatime=on -o xattr=sa $RPOOL/Linux
    zfs create -o canmount=noauto -o mountpoint=/ $RPOOL/Linux/ubuntu
    zfs mount $RPOOL/Linux/ubuntu

    zfs create -o acltype=posixacl -o dnodesize=auto -o mountpoint=/home $RPOOL/home
    zfs create -o mountpoint=/root             $RPOOL/home/root
    zfs create                                 $RPOOL/home/admin
    zfs create                                 $RPOOL/Linux/ubuntu/var
    zfs create                                 $RPOOL/Linux/ubuntu/var/lib
    zfs create                                 $RPOOL/Linux/ubuntu/var/log
    zfs create                                 $RPOOL/Linux/ubuntu/var/spool
    zfs create -o com.sun:auto-snapshot=false  $RPOOL/Linux/ubuntu/var/cach
    zfs create                                 $RPOOL/Linux/ubuntu/var/mail
    zfs create                                 $RPOOL/Linux/ubuntu/var/snap
    zfs create                                 $RPOOL/Linux/ubuntu/var/www
    zfs create -o com.sun:auto-snapshot=false  $RPOOL/Linux/ubuntu/var/lib/docker
    zfs create -o com.sun:auto-snapshot=false  $RPOOL/Linux/ubuntu/var/lib/nfs
    zfs create -o com.sun:auto-snapshot=false  $RPOOL/Linux/ubuntu/var/tmp
    chmod 1777 $MNT/var/tmp

    zfs create -o com.sun:auto-snapshot=false -o canmount=noauto $RPOOL/Linux/ubuntu/tmp
    mkdir $MNT/tmp
    chmod 1777 $MNT/tmp

    zfs create                                 $RPOOL/Linux/ubuntu/opt
    zfs create                                 $RPOOL/Linux/ubuntu/usr
    zfs create                                 $RPOOL/Linux/ubuntu/usr/local
}

zfs_system_create_bpool_datasets()
{
    zfs create $BPOOL/Boot
    zfs create -o canmount=noauto -o mountpoint=/boot $BPOOL/Boot/ubuntu
    zfs mount $BPOOL/Boot/ubuntu
}

zfs_share_service()
{
    cat <<EOF > /etc/zfs/import_custom.sh
#!/bin/sh

SCRIPT_PATH="\${0%/*}"
CUSTOM_POOLS=\${SCRIPT_PATH}/custom_pools

[ -r "\$CUSTOM_POOLS" ] || return 0

while read pool_info; do
    pool_args="\${pool_info% [A-Za-z]*}"
    pool_name="\${pool_info#\$pool_args }"
    zpool status \$pool_name >/dev/null 2>/dev/null && continue
    zpool import \$pool_info
done <  "\$CUSTOM_POOLS"
EOF

    chmod +x /etc/zfs/import_custom.sh
    touch /etc/zfs/custom_pools

    cat <<EOF > /etc/systemd/system/zfs-import-custom.service
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/zfs/import_custom.sh

[Install]
WantedBy=zfs-import.target
EOF

    systemctl enable zfs-import-custom.service
}

zfs_share_create()
{
    echo zdata > /etc/zfs/custom_pools
}

system_install_pkgs()
{
    apt -qq update
    apt -qq --yes dist-upgrade
    apt -qq --yes install software-properties-common
    apt -qq --yes install nano vim man
    apt -qq --yes install mdadm
    apt -qq --yes install dosfstools
    apt -qq --yes install parted gdisk
    apt -qq --yes install openssh-server
    apt -qq --yes install --no-install-recommends linux-image-generic
    apt -qq --yes install zfs-initramfs
}

system_reconfigure()
{
    dpkg-reconfigure locales
    dpkg-reconfigure tzdata
}

sethostid()
{
    if [ -n "$1" ]; then
        hostid="$1"
        # chars must be 0-9, a-f, A-F and exactly 8 chars
        echo "$hostid" | egrep -o '^[a-fA-F0-9]{8}$' || return 1
    else
        hostid="$(hostid)"
    fi

    hostid_tmp=${hostid%??}
    a=${hostid#$hostid_tmp}
    hostid=$hostid_tmp

    hostid_tmp=${hostid%??}
    b=${hostid#$hostid_tmp}
    hostid=$hostid_tmp

    hostid_tmp=${hostid%??}
    c=${hostid#$hostid_tmp}
    hostid=$hostid_tmp

    hostid_tmp=${hostid%??}
    d=${hostid#$hostid_tmp}
    hostid=$hostid_tmp

    /usr/bin/printf '%b' "\x$a" "\x$b" "\x$c" "\x$d" > /etc/hostid
}

root_passwd()
{
    echo set root passwd :
    passwd root
}

system_boot()
{

    cat <<EOF > /etc/systemd/system/zfs-import-bpool.service
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none $BPOOL

[Install]
WantedBy=zfs-import.target
EOF

    systemctl enable zfs-import-bpool.service

    echo $BPOOL/Boot/ubuntu /boot zfs nodev,relatime,x-systemd.requires=zfs-import-bpool.service 0 0 >> /etc/fstab
}

system_tmpfs()
{
    cp /usr/share/systemd/tmp.mount /etc/systemd/system/
    systemctl enable tmp.mount
}

system_user_admin()
{
    adduser --uid 2001 admin

    cat <<EOF > /etc/sudoers.d/admin
%admin ALL=(ALL) NOPASSWD: ALL
EOF

    chmod 0400 /etc/sudoers.d/admin

    mkdir -p /home/admin/.ssh
    chown -R admin:admin /home/admin
    chmod 0700 /home/admin
    chmod 0700 /home/admin/.ssh

    cat <<EOF > /home/admin/.ssh/authorized_keys
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDrONQB0piHJSoV+k515dk8Y4V2JVGsp+ZPQh/w9GtAV 20190731-083859
EOF
    chmod 0600 /home/admin/.ssh/authorized_keys
}

system_snapshot()
{
    zfs snapshot bpool/Boot/ubuntu@install
    zfs snapshot rpool/Linux/ubuntu@install
}

system_efi_raid()
{
    ln -sf /proc/self/mounts /etc/mtab

    mdadm --create /dev/md/efi --force --name=efi --level 1 --raid-disks 2 --metadata 1.0 ${1}-part2 ${2}-part2
    mkdosfs -F 32 -s 1 -n EFI /dev/md/efi
    mkdir /boot/efi

    MD_UUID=$(blkid -s UUID -o value /dev/md/efi)
    MD_DEVICE_UUID=$(blkid -s UUID -o value ${1}-part2)

    cat <<EOF > /etc/systemd/system/efimount.service
[Unit]
Description=Resync /boot/efi RAID
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/sbin/mdadm -A /dev/md/efi --uuid=$MD_DEVICE_UUID --update=resync
ExecStart=/bin/mount /boot/efi
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

    echo UUID=$MD_UUID /boot/efi vfat noauto,defaults 0 0 >> /etc/fstab

    systemctl enable efimount.service

    mount | grep /boot/efi || mount /boot/efi
}

system_grub()
{
    apt -qq install --yes grub-efi-amd64-signed shim-signed

    if [ "$(grub-probe /boot)" != "zfs" ]; then
        echo "\"grub-probe /boot\" output != zfs"
        exit 1
    fi

    #dpkg-reconfigure -p low grub-efi-amd64

    update-initramfs -u -k all

    sed -e 's/^\(GRUB.*\)/#\1/g' /etc/default/grub
    cat <<EOF >> /etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_RECORDFAIL_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="root=ZFS=$RPOOL/Linux/ubuntu"
GRUB_TERMINAL=console
EOF

    update-grub

    mv /bin/efibootmgr /bin/efibootmgr.real
    (cd /bin ; ln -sf efibootmgr.sh efibootmgr)

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy

    umount /boot/efi
    zfs set mountpoint=legacy bpool/Boot/ubuntu
}

system_efibootmgr()
{
    cat <<EOF > /bin/efibootmgr.sh
#!/bin/sh

die() {
        echo "\$*" >&2
        exit 1
}

run_device() {
        local devdir="\$1" label= label_set=
        local devname= dev= partition=
        shift

        if [ "x\$1" = "x-L" ]; then
                label_set=true
                label="\$2"
                shift 2
        fi

        devdir="\$(cd "\$devdir" && pwd -P)"

        if [ -s "\$devdir/partition" ]; then
                read partition < "\$devdir/partition"
                devname="\${devdir##*/}"
                devdir="\${devdir%/*}"
        fi
        dev="/dev/\${devdir##*/}"

        if [ -n "\$label_set" -a -z "\$label" ]; then
                label=\$devname
        else
                [ -n "\$label" ] || label="\$(lsb_release -si)"

                label="\$label (\$devname)"
        fi

        set -x
        "\${0%.sh}.real" "\$@" -L "\$label" -d "\$dev" \${partition:+-p \$partition}
}

run_raid() {
        local x= argv=
        local label= label_set= label_next=
        local device= devdir=
        local md_level= md_disks=

        # extract label
        for x; do
                if [ "\$x" = "-L" ]; then
                        label_next=true
                        label_set=
                        label=
                elif [ -n "\$label_next" ]; then
                        label_next=
                        label_set=true
                        label="\$x"
                else
                        x=\$(echo -n "\$x" | sed -e 's|"|\\\\"|g')
                        argv="\$argv \"\$x\""
                fi
        done

        if [ -n "\$label_set" ]; then
                x=\$(echo -n "\$label" | sed -e 's|"|\\\\"|g')
                argv="-L \"\$x\" \$argv"
        fi

        device="\$(grep ' /boot/efi ' /proc/mounts | cut -d' ' -f1)"
        [ -b "\$device" ] || die "ESP not mounted"
        device="\$(readlink -f "\$device")"
        devdir=/sys/class/block/\${device##*/}

        if read md_level < \$devdir/md/level 2> /dev/null; then
                if [ "\$md_level" = raid1 ]; then
                        read md_disks < \$devdir/md/raid_disks
                        for i in \`seq \$md_disks\`; do
                                set +x
                                eval "run_device '\$devdir/md/rd\$((\$i - 1))/block' \$argv"
                        done
                else
                        die "RAID \$md_level not supported"
                fi
        else
                # not RAID
                set -x
                eval "run_device '\$devdir' \$argv"
        fi
        exit 0
}

run_normal() {
        exec "\${0%.sh}.real" "\$@"
}

set -eu

argv=
i=1
for x; do
        if [ "\$x" = "-d" -a \$i -eq \$# ]; then
                # /boot/efi is /dev/md and grub-install can't handle it yet
                eval "run_raid \$argv"
                die "never reached"
        fi

        : \$((i = i+1))
        x=\$(echo -n "\$x" | sed -e 's|"|\\\\"|g')
        argv="\$argv \"\$x\""
done

set -x
eval "run_normal \$argv"
EOF

    chmod +x /bin/efibootmgr.sh
}

system_disable_log_compression()
{
    for file in /etc/logrotate.d/* ; do
        if grep -Eq "(^|[^#y])compress" "$file" ; then
            sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "$file"
        fi
    done
}

########## MAIN

do_prereq()
{
    apt -qq update
    apt -qq install -y debootstrap
    apt -qq install -y gdisk mdadm
    apt -qq install -y dosfstools
    apt -qq install -y zfs-initramfs || echo OK
}

do_system_fs()
{
    [ -z "$1" ] && return 1
    [ -z "$2" ] && return 1

    disk_format_system "$1" &&
        disk_format_system "$2" &&
        zfs_system_create "$1" "$2"
    set +x
}

do_install_ubuntu()
{
    debootstrap $CODENAME $MNT

    zfs set devices=off $RPOOL

    echo $HOSTNAME > $MNT/etc/hostname

    cp /etc/netplan/00-installer-config.yaml $MNT/etc/netplan/01-netcfg.yaml

    mkdir -p $MNT/root/install/
    cp "$0" $MNT/root/install/
}

do_install()
{
    if [ $# -ne 2 ]; then
        echo "Please specify 2 disks for system install :"
        disk_list
        return 1
    fi

    set -x
    do_prereq &&
        do_system_fs "$1" "$2" &&
        do_install_ubuntu &&
        do_chroot
}

do_mount()
{
    mount | grep "^$RPOOL/Linux/ubuntu on" || zfs mount $RPOOL/Linux/ubuntu
    mount | grep "^$BPOOL/Boot/ubuntu on" || zfs mount $BPOOL/Boot/ubuntu
}

do_mount_specials()
{
    mount --rbind /dev  $MNT/dev
    mount --rbind /proc $MNT/proc
    mount --rbind /sys  $MNT/sys
}

do_chroot()
{
    do_mount &&
        do_mount_specials &&
        echo continue with : &&
        echo chroot $MNT /bin/bash --login
}

do_set_systemctl_default()
{
    systemctl set-default multi-user.target
}

do_postinstall()
{
    if [ $# -ne 2 ]; then
        echo "Please specify 2 disks for system install :"
        disk_list
        return 1
    fi

    set -x
    sethostid &&
        system_install_pkgs &&
        system_reconfigure &&
        system_boot &&
        system_tmpfs &&
        system_efi_raid "$1" "$2" &&
        system_efibootmgr &&
        system_grub &&
        system_disable_log_compression &&
        root_passwd &&
        do_set_systemctl_default
}

do_reboot()
{
    mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
    zpool export -a
    sleep 1
    reboot
}

do_share()
{
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        echo specify 1 or 2 disks to build share system :
        disk_list
        return 1
    fi

    zfs_share_service &&
        zfs_share_create
}


usage()
{
    cat <<EOF
Usage is :
    $0 <action> <action_args>

With action in :
    h | help
    i | install <disk1> <disk2>
    c | chroot
    p | postinstall
    s | sethostid
    r | reboot
EOF
}

action="$1"
[ $# -gt 0 ] && shift
case "$action" in
    h|help|"")
        usage
        exit 0
        ;;
    i|install)
        do_install "$@"
        ;;
    c|chroot)
        do_chroot
        ;;
    p|postinstall)
        do_postinstall "$@"
        ;;
    s|sethostid)
        sethostid "$@"
        ;;
    r|reboot)
        do_reboot
        ;;
    efibootmgr)
        system_efibootmgr
        ;;
    share)
        do_share "$@"
        ;;
    *)
        usage
        exit 1
        ;;
esac
