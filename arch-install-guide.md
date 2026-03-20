# Arch Linux: Modern Secure Boot Stack

---

## Table of Contents

**Setup**
- [00. Overview & Goals](#00-overview-goals)
- [01. Live Environment](#01-live-environment)
- [02. Partition Disk](#02-partition-disk)
- [03. LUKS2 Encryption](#03-luks2-encryption)
- [04. Btrfs & Subvolumes](#04-btrfs-subvolumes)
- [05. Mount Filesystems](#05-mount-filesystems)

**Installation**
- [06. pacstrap Base System](#06-pacstrap-base-system)
- [07. fstab & chroot](#07-fstab-chroot)
- [08. System Configuration](#08-system-configuration)
- [09. Configure dracut](#09-configure-dracut)
- [10. kernel-install & UKI Generation](#10-kernel-install-uki-generation)

**Boot**
- [11. Install systemd-boot](#11-install-systemd-boot)
- [12. Finalise & Reboot](#12-finalise-reboot)

**Post-install**
- [13. Package Cache & Mirror Management](#13-package-cache-mirror-management)

---

## Overview & Goals

This guide replaces the default mkinitcpio stack with dracut + kernel-install, producing Unified Kernel Images (UKI) that live on the ESP. The root filesystem is LUKS2-encrypted Btrfs with subvolumes.

### What you'll end up with

```
nvme0n1 (GPT)
  ├─ nvme0n1p1 FAT32 /efi ← ESP (≥ 1 GiB recommended)
  └─ nvme0n1p2 LUKS2 ← encrypted container
    └─ /dev/mapper/cryptroot Btrfs
    ├─ @ /
    ├─ @home /home
    ├─ @snapshots /.snapshots
    ├─ @var_log /var/log
    └─ @var_cache /var/cache/pacman/pkg
```

> [!NOTE]
> **ESP on /efi, not /boot.** All UKI images are written directly to `/efi/EFI/Linux/` by kernel-install. The kernel and initramfs never live in /boot on disk.

> [!WARNING]
> **UEFI only.** This setup requires a UEFI system. Legacy BIOS/MBR is not supported by this configuration.

### Key technology choices

**dracut** — generates the initramfs with built-in LUKS/systemd support, and can embed cmdline + kernel into a single EFI binary (UKI). Unlike mkinitcpio, it uses a systemd-based init inside the initramfs natively.

**kernel-install** — a script (from systemd) that, on kernel installation, automatically calls dracut and installs the resulting UKI to the ESP. Hooks into pacman via install scripts.

**UKI (Unified Kernel Image)** — a single `.efi` file containing kernel + initramfs + cmdline + os-release. It can be directly booted by firmware or by systemd-boot. Enables measured boot and Secure Boot signing later.

**systemd-boot** — a minimal EFI boot manager. It discovers UKIs automatically in `/efi/EFI/Linux/` with no extra config files needed.

---

## 01. Live Environment

Boot the Arch ISO and prepare the live environment before touching the disk.

### Step 1: Set keyboard layout

The Arch ISO defaults to `us`. Load the Italian layout for the live session so passwords and paths are typed correctly from the start.

```bash
loadkeys it
```

> [!WARNING]
> Set the layout **before** typing your LUKS passphrase during `cryptsetup luksFormat`. A passphrase typed with the wrong layout will be impossible to reproduce correctly on reboot.

> [!TIP]
> `loadkeys` only sets the keymap for the current live session. The persistent setting for the installed system is done later with `localectl set-keymap --no-convert it` in the chroot (section 08). To browse available keymaps: `localectl list-keymaps | grep it`.

### Step 2: Verify UEFI boot mode

```bash
cat /sys/firmware/efi/fw_platform_size
# Must output 64 (or 32 for 32-bit UEFI)
```

### Step 3: Connect to the internet

Wired: usually works automatically. Wireless:

```bash
iwctl
# [iwd] device list
# [iwd] station wlan0 scan
# [iwd] station wlan0 get-networks
# [iwd] station wlan0 connect "SSID"
# [iwd] quit

ping -c3 archlinux.org
```

### Step 4: Sync clock & update mirrors

```bash
timedatectl set-ntp true
reflector --country "Germany,France" --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
```

> [!TIP]
> Adjust `--country` to your nearest countries for best speeds.

---

## 02. Partition the Disk

Create two partitions: an EFI System Partition and a LUKS container. Adjust /dev/nvme0n1 to your actual disk.

### Step 1: Identify your disk

```bash
lsblk -o NAME,SIZE,TYPE,MODEL
```

### Step 2: Wipe & create GPT table with fdisk

> [!DANGER]
> **This destroys all data on the disk.** Double-check the device name before proceeding.

```bash
fdisk /dev/nvme0n1

# Inside fdisk:
#  g          → new GPT partition table
#  n          → new partition (p1, default start, +1G) → EFI
#  t → 1      → type: EFI System (1)
#  n          → new partition (p2, default start, default end) → Linux root
#  t → 23       → type: Linux root x86-64 (23)
#  w          → write and quit
```

> [!NOTE]
> Use at least **1 GiB** for the ESP. With UKIs, each kernel version produces its own ~60–100 MB EFI binary stored there. 512 MiB is too small if you keep multiple kernels.

### Step 3: Format the ESP

```bash
mkfs.fat -F32 -n EFI /dev/nvme0n1p1
```

---

## 03. LUKS2 Encryption

Encrypt the root partition with LUKS2 using Argon2id key derivation — significantly stronger than the LUKS1 default PBKDF2.

### Step 1: Create the LUKS2 container

```bash
cryptsetup luksFormat \
--type luks2 \
--cipher aes-xts-plain64 \
--key-size 512 \
--hash sha512 \
--pbkdf argon2id \
--iter-time 3000 \
--label CRYPTROOT \
/dev/nvme0n1p2
```

> [!WARNING]
> You must type `YES` in uppercase to confirm. Choose a strong passphrase — this is your only encryption key (you can add a keyfile later with `cryptsetup luksAddKey`).

### Step 2: Open the container

```bash
cryptsetup open /dev/nvme0n1p2 cryptroot
# → /dev/mapper/cryptroot is now available
```

---

## 04. Btrfs & Subvolumes

Format the LUKS container as Btrfs and create a logical subvolume layout that enables snapshotting and selective CoW control.

### Step 1: Create the Btrfs filesystem

```bash
mkfs.btrfs -L ARCH /dev/mapper/cryptroot
```

### Step 2: Mount the top-level and create subvolumes

```bash
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache

umount /mnt
```

> [!TIP]
> `@var_log` and `@var_cache` as separate subvolumes excludes them from root snapshots, preventing large or frequently-written data from bloating snapshots.

---

## 05. Mount Filesystems

Mount all subvolumes and the ESP with the correct options before running pacstrap.

### Step 1: Mount root and all subvolumes

```bash
# Common btrfs options
OPTS = "noatime,compress=zstd:1,space_cache=v2"

mount -o ${OPTS},subvol=@ /dev/mapper/cryptroot /mnt

mkdir -p /mnt/{efi,home,.snapshots,var/log,var/cache/pacman/pkg}

mount -o ${OPTS},subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o ${OPTS},subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount -o ${OPTS},subvol=@var_log /dev/mapper/cryptroot /mnt/var/log
mount -o ${OPTS},subvol=@var_cache /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
```

### Step 2: Mount the ESP at /efi

```bash
mount --mkdir /dev/nvme0n1p1 /mnt/efi
```

> [!NOTE]
> The ESP is mounted at `/efi`, **not** `/boot`. This means `/boot` lives on the encrypted Btrfs root — only the final UKI EFI binary is unencrypted on the ESP.

---

## 06. pacstrap Base System

Install the base system. Note: we do not install mkinitcpio. We'll install dracut instead after chrooting.

### Step 1: Install base packages

```bash
pacstrap -K /mnt \
base \
linux \
linux-headers \
linux-firmware \
btrfs-progs \
cryptsetup \
dracut \
systemd-ukify \
plymouth \
efibootmgr \
base-devel \
vim \
networkmanager \
intel-ucode \
amd-ucode
```

> [!NOTE]
> Install **both** `intel-ucode` and `amd-ucode` regardless of your CPU. dracut's `early_microcode=yes` automatically selects only the correct one for the running hardware at build time, so there is no cost to having both present.

> [!WARNING]
> Do **not** install `mkinitcpio`. The `linux` package will try to run mkinitcpio hooks on install — that's fine for now; we'll replace the initramfs with dracut after configuring it in chroot. The UKI won't be built until kernel-install is properly configured.

---

## 07. fstab & chroot

Generate the filesystem table and enter the new system.

### Step 1: Generate fstab

```bash
genfstab -U /mnt >> /mnt/etc/fstab
cat /mnt/etc/fstab # verify it looks correct
```

> [!TIP]
> Verify the fstab: you should see entries for `/`, `/home`, `/.snapshots`, `/var/log`, `/var/cache/pacman/pkg` (all Btrfs with subvol= options) and `/efi` (vfat). There should be **no** separate `/boot` entry.

### Step 2: Enter the chroot

```bash
arch-chroot /mnt
```

---

## 08. System Configuration

Configure locale, timezone, hostname, and user accounts inside the chroot.

### Step 1: Timezone & locale

```bash
ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime
hwclock --systohc

# Uncomment your locale(s) in /etc/locale.gen, e.g. it_IT.UTF-8
sed -i 's/#it_IT.UTF-8/it_IT.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=it_IT.UTF-8" > /etc/locale.conf
```

### Step 2: Console keymap (persistent)

Use `localectl` to set the console keymap and X11 keymap independently. The `--no-convert` flag prevents localectl from auto-deriving one from the other.

```bash
# Set console (TTY) keymap — writes KEYMAP= to /etc/vconsole.conf
localectl set-keymap --no-convert it

# Set X11 keymap — writes to /etc/X11/xorg.conf.d/00-keyboard.conf
localectl set-x11-keymap --no-convert it
```

> [!TIP]
> Verify with `localectl status` — you should see both **VC Keymap: it** and **X11 Layout: it**.

> [!NOTE]
> You may also want to set a console font in `/etc/vconsole.conf` after localectl writes it. Add `FONT=eurlatgr` to cover Italian accented characters — verify it exists first with `ls /usr/share/kbd/consolefonts/eurlatgr*`. If missing, install `kbd` with `pacman -S kbd`. If `systemd-vconsole-setup.service` fails on boot, omit the `FONT=` line to narrow it down.

> [!TIP]
> dracut picks up `/etc/vconsole.conf` automatically and includes the keymap in the initramfs — the Italian layout will be active at the LUKS passphrase prompt on boot.

### Step 3: Hostname & hosts

```bash
echo "mymachine" > /etc/hostname
```

/etc/hosts

127.0.0.1   localhost
::1         localhost
127.0.1.1   mymachine.localdomain  mymachine

### Step 4: Root password & user

```bash
passwd

useradd -mG wheel,audio,video myuser
passwd myuser

# Enable sudo for wheel group:
EDITOR=vim visudo # uncomment: %wheel ALL=(ALL:ALL) ALL
```

### Step 5: Get the LUKS partition UUID

You'll need this for the kernel command line in the next steps:

```bash
blkid -s UUID -o value /dev/nvme0n1p2
# You'll need this for /etc/kernel/cmdline in section 10
```

---

## 09. Configure dracut

When kernel-install drives the build, dracut acts as a subordinate tool — it builds the initramfs and assembles the UKI, but kernel-install controls the paths, cmdline, and EFI stub. dracut.conf only expresses how to build — modules, compression, microcode. The cmdline, splash, and stub are owned by ukify via /etc/kernel/cmdline and /etc/kernel/uki.conf .

### Step 1: Main dracut configuration

```bash
vim /etc/dracut.conf.d/10-main.conf
```

```
# Modules: systemd init, LUKS (crypt) + systemd-cryptsetup (dracut ≥102)
add_dracutmodules+=" systemd crypt "
 
# Compress the initramfs
compress="zstd"
 
# Embed CPU microcode as early CPIO (intel-ucode / amd-ucode)
early_microcode="yes"
```

> [!NOTE]
> No `uefi=`, `uefi_stub=`, `uefi_dir=`, `kernel_cmdline=`, or `uefi_splash=` here. Those are now owned by ukify via `/etc/kernel/uki.conf` and `/etc/kernel/cmdline`. dracut.conf is purely about initramfs construction.

### Step 2: Btrfs module

```bash
vim /etc/dracut.conf.d/20-btrfs.conf
```

```
add_dracutmodules+=" btrfs "
filesystems+=" btrfs "
```

### Step 3: Host-only mode

```bash
vim /etc/dracut.conf.d/30-host.conf
```

```
# Only include modules needed for this hardware — smaller, faster UKI
hostonly="yes"
hostonly_cmdline="no"
```

> [!TIP]
> `hostonly=yes` produces a lean UKI by only including what your current hardware needs. The resulting image won't boot on a different machine without rebuilding — that's fine for a personal install.

### Step 4: Mask dracut's own pacman hooks

dracut ships two pacman hooks that call dracut directly on kernel install/remove, bypassing kernel-install entirely. Mask them with null symlinks so they fire but do nothing:

```bash
ln -s /dev/null /etc/pacman.d/hooks/90-dracut-install.hook
ln -s /dev/null /etc/pacman.d/hooks/60-dracut-remove.hook
```

> [!NOTE]
> A symlink to `/dev/null` at the same path as a system hook is the standard pacman way to mask it. Pacman finds the local hook first and treats it as empty, so the system-provided one in `/usr/share/libalpm/hooks/` is never executed.

---

## 10. kernel-install & UKI Generation

kernel-install orchestrates the whole build: it reads config, invokes dracut via the 50-dracut.install plugin, passes the EFI stub, cmdline, and output path, then copies the resulting UKI to the ESP.

### Step 1: Configure kernel-install

```bash
vim /etc/kernel/install.conf
```

```
layout=uki
```

> [!NOTE]
> `layout=uki` is the only key needed here. kernel-install will use ukify (via `systemd-ukify`) to assemble the final UKI, with dracut generating the initramfs as part of that process.

### Step 2: Kernel command line

kernel-install reads the cmdline from `/etc/kernel/cmdline` and passes it to ukify, which embeds it into the UKI.

```bash
vim /etc/kernel/cmdline
```

```
rd.luks.uuid=<YOUR-LUKS-UUID> rd.luks.name=<YOUR-LUKS-UUID>=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ splash quiet rw
```

> [!WARNING]
> Replace both instances of `<YOUR-LUKS-UUID>` with the UUID from `blkid -s UUID -o value /dev/nvme0n1p2`. Single line, no trailing newline.

> [!NOTE]
> If this file does not exist, kernel-install falls back to `/proc/cmdline` — the live ISO's parameters in a chroot. Always create it explicitly.

### Step 3: UKI configuration — splash & EFI stub

ukify reads `/etc/kernel/uki.conf` for UKI-specific settings like the splash screen and EFI stub path. These are no longer set in dracut.conf.

```bash
vim /etc/kernel/uki.conf
```

```
[UKI]
Splash=/usr/share/systemd/bootctl/splash-arch.bmp
```

> [!TIP]
> The splash image is displayed by the firmware as soon as the UKI is executed, before the kernel starts. The BMP ships with the `systemd` package — no extra install needed.

### Step 3: Create the kernel-install pacman hooks

See section 09 step 4 for masking dracut's hooks. Now create the hooks that trigger kernel-install instead.

Helper script called by both hooks:

```bash
vim /usr/local/bin/kernel-install-hook
```

```
#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit nullglob
 
cd /
all_kernels=0
declare -A versions
 
add_file() {
    local kver="$1"
    kver="${kver##usr/lib/modules/}"
    kver="${kver%%/*}"
    versions["$kver"]=""
}
 
# Read matched paths from stdin (provided by NeedsTargets)
while read -r path; do
    case "$path" in
    usr/lib/modules/*/vmlinuz | usr/lib/modules/*/extramodules/*)
        add_file "$path" ;;
    *)
        # Non-kernel trigger (dracut, firmware, ucode...)
        all_kernels=1 ;;
    esac
done
 
# If triggered by a non-kernel path, rebuild for all installed kernels
if (( all_kernels )); then
    for file in usr/lib/modules/*/vmlinuz; do
        pacman -Qqo "$file" >/dev/null 2>&1 && add_file "$file"
    done
fi
 
for kver in "${!versions[@]}"; do
    kimage="/usr/lib/modules/$kver/vmlinuz"
    kernel-install "$@" "$kver" "$kimage" || true
done
```

```bash
chmod 755 /usr/local/bin/kernel-install-hook
```

The add hook:

```bash
vim /etc/pacman.d/hooks/90-kernel-install-add.hook
```

```
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz
 
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = usr/lib/firmware/*
Target = usr/lib/modules/*/extramodules/*
Target = usr/src/*/dkms.conf
Target = usr/lib/dracut/*
Target = usr/lib/dracut/*/*
Target = usr/lib/dracut/*/*/*
Target = usr/lib/kernel/*
Target = usr/lib/kernel/*/*
Target = boot/*-ucode.img
 
[Action]
Description = Installing kernel and initrd using kernel-install...
When = PostTransaction
Exec = /usr/local/bin/kernel-install-hook add
NeedsTargets
```

The remove hook:

```bash
vim /etc/pacman.d/hooks/40-kernel-install-remove.hook
```

```
[Trigger]
Type = Path
Operation = Upgrade
Operation = Remove
Target = usr/lib/modules/*/vmlinuz
 
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = usr/lib/firmware/*
Target = usr/lib/modules/*/extramodules/*
Target = usr/src/*/dkms.conf
Target = usr/lib/dracut/*
Target = usr/lib/dracut/*/*
Target = usr/lib/dracut/*/*/*
Target = usr/lib/kernel/*
Target = usr/lib/kernel/*/*
Target = boot/*-ucode.img
 
[Action]
Description = Removing kernel and initrd using kernel-install...
When = PostTransaction
Exec = /usr/local/bin/kernel-install-hook remove
NeedsTargets
```

> [!TIP]
> The second `[Trigger]` block fires when dracut itself updates, or when firmware/ucode/DKMS modules change — not just when the kernel vmlinuz changes. The script's `all_kernels` flag handles these cases by rebuilding UKIs for every currently installed kernel.

### Step 4: Build the UKI now

```bash
# Get the installed kernel version
KVER =$( ls /usr/lib/modules)
echo $KVER # e.g. 6.x.y-arch1-1

kernel-install -v add ${KVER} /usr/lib/modules/${KVER}/vmlinuz

# Verify the UKI was created on the ESP
find /efi -name "*.efi"
```

> [!TIP]
> The `-v` flag shows the full plugin execution log — useful for verifying that `50-dracut.install` is called with `--uefi` (not `--no-uefi`) and that `90-uki-copy.install` succeeds.

> [!TIP]
> Verify the cmdline was embedded: `objdump -j .cmdline -s $(find /efi -name "*.efi")`

---

## 11. Install systemd-boot

systemd-boot is a minimal EFI boot manager that auto-discovers UKIs from /efi/EFI/Linux/ — minimal configuration needed.

### Step 1: Install bootloader to ESP

```bash
bootctl --esp-path=/efi install
```

This installs systemd-boot to `/efi/EFI/systemd/` and creates an NVRAM boot entry.

### Step 2: Loader configuration (optional but recommended)

```bash
vim /efi/loader/loader.conf
```

```
default      @saved
timeout      3
console-mode max
editor       no
```

> [!TIP]
> `editor no` prevents anyone from modifying the kernel cmdline at boot — since it's baked into the UKI anyway, this is purely defensive. `@saved` boots the last manually selected entry.

> [!NOTE]
> You do **not** need to create any `/efi/loader/entries/*.conf` files. systemd-boot automatically discovers UKIs placed in `/efi/EFI/Linux/` thanks to the `Type#2` boot entry discovery spec.

### Step 3: Enable automatic bootloader updates

```bash
systemctl enable systemd-boot-update.service
```

This service updates the bootloader binaries on the ESP whenever systemd-boot itself is updated via pacman.

---

## 12. Finalise & Reboot

Last checks before leaving the chroot and rebooting into your new system.

### Step 1: Enable essential services

```bash
systemctl enable NetworkManager
systemctl enable systemd-resolved
```

### Step 2: Final verification checklist

```bash
# 1. UKI exists on ESP
ls /efi/EFI/Linux/

# 2. systemd-boot is installed
bootctl status

# 3. fstab looks correct
cat /etc/fstab

# 4. LUKS UUID in /etc/kernel/cmdline matches blkid
cat /etc/kernel/cmdline
blkid -s UUID -o value /dev/nvme0n1p2
```

### Step 3: Exit, unmount, reboot

```bash
exit # leave chroot
umount -R /mnt
cryptsetup close cryptroot
reboot
```

> [!TIP]
> On first boot you'll be prompted for your LUKS passphrase by the systemd cryptsetup agent inside the initramfs. After unlocking, the Btrfs root mounts automatically and the system boots.

## 13. Package Cache & Mirror Management

Keep the package cache lean with paccache and the mirror list fast with reflector. Both integrate with systemd timers for zero-maintenance operation.

### Step 1: Install pacman-contrib & reflector

```bash
sudo pacman -S pacman-contrib reflector
```

### Step 2: paccache — automatic cache cleanup

`paccache` removes old cached package versions, keeping the last N for potential rollback. The included systemd timer runs it weekly.

```bash
sudo systemctl enable --now paccache.timer
```

> [!NOTE]
> By default `paccache -r` keeps the **3 most recent versions** of each package. This is intentional — those cached versions are what makes downgrade-based rollbacks possible. Aggressive cleanup breaks that.

> [!TIP]
> To keep fewer versions (e.g. 2), override the service with a drop-in: `sudo systemctl edit paccache.service` and set `ExecStart=/usr/bin/paccache -rk2`.

Useful manual invocations:

```bash
# Dry-run: see what would be removed
paccache -d

# Remove old versions (keep 3)
sudo paccache -r

# Remove ALL cached versions of uninstalled packages
sudo paccache -ruk0
```

### Step 3: reflector — automatic mirror ranking

`reflector` fetches the Arch mirror list, filters by country/protocol/age, sorts by speed, and writes the result to `/etc/pacman.d/mirrorlist`. Configure it once in its config file:

```bash
vim /etc/xdg/reflector/reflector.conf
```

```
# Save to the standard mirrorlist path
--save /etc/pacman.d/mirrorlist
 
# HTTPS only
--protocol https
 
# Italian mirrors first, fallback to nearby countries
--country Italy,Germany,France,Switzerland
 
# Only mirrors synced in the last 12 hours
--age 12
 
# Rank by download speed, keep 10 fastest from top 20
--sort rate
--latest 20
--number 10
--connection-timeout 5
```

```bash
sudo systemctl enable --now reflector.timer
```

> [!WARNING]
> reflector **overwrites** `/etc/pacman.d/mirrorlist` on every run. Hand-edits to that file will be lost. The config above is the canonical place for your preferences.

Run on demand:

```bash
sudo systemctl start reflector.service
journalctl -fu reflector.service
```

### Step 4: pacman hook — refresh mirrors when pacman-mirrorlist updates

The `pacman-mirrorlist` package occasionally ships a new default mirrorlist that overwrites yours. This hook re-runs reflector after any such upgrade:

```bash
vim /etc/pacman.d/hooks/mirrorlist.hook
```

```
[Trigger]
Operation = Upgrade
Type = Package
Target = pacman-mirrorlist
[Action]
Description = Updating mirrorlist with reflector...
When = PostTransaction
Depends = reflector
Exec = /usr/bin/reflector --config /etc/xdg/reflector/reflector.conf
```

---

### Further recommendations

**Snapper** — install `snapper` and configure it for the `@` and `@home` subvolumes for automatic Btrfs snapshots.

**TPM2 unlock** — enroll your LUKS key into the TPM2 chip with `systemd-cryptenroll --tpm2-device=auto /dev/nvme0n1p2` so you don't need to type the passphrase on trusted boots.

**Secure Boot** — use `sbctl` to create your own Secure Boot keys and sign the UKI. dracut's UKI format is designed exactly for this workflow.