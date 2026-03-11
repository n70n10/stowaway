# Arch Linux post install

Install Arch with archinstall:

1. Manual partition. 4 GiB /efi, rest btrfs with @, @home, @log, @cache
2. LUKS encryption for root partition
3. systemd-boot bootloader UKI enabled
4. Minimal install (no DE or WM)
5. Add a text editor (I like micro)

## 1. Basics
### 1.1. Install packages
```bash
./install.sh
```
### 1.2. Add some color to pacman
```bash
sudo micro /etc/pacman.conf
````
uncommect Color and add these lines:
```
ILoveCandy
VerbosePkgLists
```
### 1.3. Cleanup package cache
install pacman-contrib package
```bash
sudo pacman -S pacman-contrib
```
edit pacman-contrib
```bash
sudo micro /etc/conf.d/pacman-contrib
```
to look like
```
PACCACHE_ARGS="-k2 -u"
```
enable the cleanup timer
```bash
sudo systemctl enable --now paccache.timer
```
### 1.4. Mirrorlist
install reflector
```bash
sudo pacman -S reflector
```
edit reflector.conf
```bash
sudo micro /etc/xdg/reflector/reflector.conf
```
I usually leave the defaults, and change country to something like
```
--country France,Germany,Netherlands
```
start the timer
```bash
sudo systemctl enable --now reflector.timer
```
### 1.5. Check /efi permissions
Ideally /efi should be mounted with fmask=0077,dmask=0077. If that's not the case run
```bash
sudo chmod 700 /efi
```
and edit the /efi entry in /etc/fstab so that fmask=0077,dmask=0077. Reboot and run
```bash
mount | grep /efi
```
to be sure
## 2. Dracut
transition from mkinitcpio to dracut
### 2.1. Install dracut
```bash
sudo pacman -S dracut cpio systemd-ukify
```
### 2.2. Create dracut config
```
sudo micro /etc/dracut.conf.d/uki.conf
```
add this content
```
add_dracutmodules+=" systemd crypt "
hostonly="yes"
compress="zstd"
early_microcode="yes"
```
### 2.3. add kernel-install config files
run these
```bash
echo "layout=uki" | sudo tee /etc/kernel/install.conf
```
```bash
echo "rd.luks.uuid=$(lsblk -f | grep crypto_LUKS | awk '{print $4}') root=UUID=$(findmnt -no UUID /) rootfstype=btrfs rootflags=compress=zstd:3,subvol=@ rw splash quiet" | sudo tee /etc/kernel/cmdline
```
```bash
echo "arch" | sudo tee /etc/kernel/entry-token
```
```bash
cat <<EOF | sudo tee /etc/kernel/uki.conf
[UKI]
Splash=/usr/share/systemd/bootctl/splash-arch.bmp
EOF
```
### 2.4. Add kernel-install hook
we need to replace two dracut (or mknintcpio) hooks with kernel-install
```bash
sudo micro /etc/pacman.d/hooks/90-kernel-install.hook
```
add this
```
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Operation = Remove
Target = linux
Target = linux-lts
Target = linux-zen
Target = linux-hardened

[Action]
Description = Managing Unified Kernel Images via kernel-install...
When = PostTransaction
# We use a shell loop to catch the actual kernel version string
Exec = /usr/bin/bash -c 'while read -r line; do /usr/bin/kernel-install add "$line" "/usr/lib/modules/$line/vmlinuz"; done < <(ls /usr/lib/modules | grep arch)'
Depends = systemd-ukify
Depends = dracut
NeedsTargets
```
### 2.5. Cleanup and test
remove mkinitcpio and its configuration files
```bash
sudo pacman -Rsn mkinitcpio
sudo rm -rf /etc/mkinitcpio.*
```
remove dracut hooks
```bash
sudo ln -s /dev/null /etc/pacman.d/hooks/60-dracut-remove.hook
sudo ln -s /dev/null /etc/pacman.d/hooks/90-dracut-install.hook
```
force rebuild the uki image
```bash
sudo kernel-install -v add $(uname -r) /usr/lib/modules/$(uname -r)/vmlinuz
```
and reboot
## 3. Snapper
### 3.1. Install snapper
```bash
sudo pacman -S snapper snap-pac
```
### 3.2. Create @snapshots subvolume
```bash
#your luks uuid will be different
sudo mount -o subvolid=5 /dev/mapper/luks-241758c6-9945-455e-abc5-5956aabbf663 /mnt
sudo btrfs subvolume create /mnt/@snapshots
sudo umount /mnt
```
edit your fstab to include the newly created subvolume
```bash
sudo micro /etc/fstab
```
again, your UUID will be different
```
UUID=170cdcab-a15b-4f5b-a55d-512f78b22ed9       /.snapshots btrfs       rw,relatime,compress=zstd:3,ssd,space_cache=v2,subvol=/@snapshots       0 0
```
create snapper config for root
```bash
sudo snapper -c root create-config /
```
replace the auto-created directory with a subvolume
```
sudo btrfs subvolume delete /.snapshots
sudo mkdir /.snapshots
sudo systemctl daemon-reload
sudo mount /.snapshots
```
### 3.3. Add systemd-boot support
install systemd-boot-snapper-tools from github
```bash
git clone https://github.com/n70n10/systemd-boot-snapper-tools.git
cd systemd-boot-snapper-tools
sudo make install
```
to test everything, create a snapshot
```bash
sudo snapper -c root create -d "1st snapshot"
```
check that /boot/loader/entries has been correctly updated and reboot
### 3.4. Cleanup snapshots
edit snapper config
```bash
sudo micro /etc/snapper/configs/root
```
to something like
```
# users and groups allowed to work with config
ALLOW_USERS="<your user>"
ALLOW_GROUPS="wheel"

# sync users and groups from ALLOW_USERS and ALLOW_GROUPS to .snapshots
# directory
SYNC_ACL="no"


# start comparing pre- and post-snapshot in background after creating
# post-snapshot
BACKGROUND_COMPARISON="yes"


# run daily number cleanup
NUMBER_CLEANUP="yes"

# limit for number cleanup
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"


# create hourly snapshots
TIMELINE_CREATE="yes"

# cleanup hourly snapshots after some time
TIMELINE_CLEANUP="yes"

# limits for timeline cleanup
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="2"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_QUARTERLY="0"
TIMELINE_LIMIT_YEARLY="0"


# cleanup empty pre-post-pairs
EMPTY_PRE_POST_CLEANUP="yes"

# limits for empty pre-post-pair cleanup
EMPTY_PRE_POST_MIN_AGE="1800"
```
enable the cleanup timers
```bash
sudo systemctl enable --now snapper-timeline.timer
sudo systemctl enable --now snapper-cleanup.timer
```
