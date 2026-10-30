# Portable USB installer: `devoid-usb.sh`

This is the intentionally less opinionated cousin of the secured
installer: conventional Debian on a removable disk, useful for
a portable system, testing or rescue. **It does not provide the
full installer's LUKS2/TPM2/FIDO2/Secure Boot trust chain.**

## What it does

- GPT with a 2 GiB FAT32 ESP (changeable through environment
  variable `ESP_SIZE`) and an XFS root filling the remainder.
- `mmdebstrap`, Debian release `forky` by default (changeable via
  `DEBIAN_RELEASE`), dracut **generic** initramfs and unsigned UKIs.
- `systemd-boot` installed to `EFI/BOOT/BOOTX64.EFI` in removable
  fallback mode with `bootctl --no-variables`.
- No LUKS, TPM enrollment, FIDO2, PIV, signing, key database
  enrollment, or firmware boot-entry manipulation.
- Packaged Atheros/Intel networking and AMD/Intel/NVIDIA GPU
  firmware, including some legacy devices with interactive license
  terms.
- NVIDIA CUDA, AMD ROCm and Intel oneAPI **APT repositories**, but
  not the large toolkits or proprietary/DKMS drivers themselves.
- NetworkManager, systemd-resolved, SSH server and standard
  maintenance tools.
- A normal prompted root password.
- **Copies the live host's NetworkManager profiles** into the USB,
  including potentially sensitive network credentials.

## Requirements and warning

The selected disk is erased. The script checks that the target is a
whole disk and refuses a disk containing the current mounted root
filesystem. That protects one obvious error, **not** a separate
data disk that you happen to select by mistake. Confirm the model,
serial and persistent by-id path.

It can be launched from an existing Debian installation, without
entering firmware Setup Mode. It does **not** alter `Boot####` entries.
However, its **unsigned** UKIs may be refused by systems with
Secure Boot enforcement. Do not assume that a USB that boots on
one host will boot on every Secure Boot configuration.

## Installation

From a **ROOT** shell, with network access:

```sh
lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,MOUNTPOINTS
readlink -f /dev/disk/by-id/usb-YOUR-DEVICE
bash ./devoid-usb.sh /dev/disk/by-id/usb-YOUR-DEVICE
```

The script displays a destructive confirmation dialog containing the
disk identity. Read it. To override the release and ESP size:

```sh
DEBIAN_RELEASE=forky ESP_SIZE=2G \
  bash ./devoid-usb.sh /dev/disk/by-id/usb-YOUR-DEVICE
```

The target phase runs inside `systemd-nspawn` without passing the
host's TPM/FIDO2/efivarfs or raw block devices. Unlike the secured
installer, this is designed to minimize interaction with firmware.

## Firmware and compute repositories

The installer sets up packaged firmware before regenerating the UKIs,
with `dracut` `hostonly="no"` so it is not tied to the machine used
to build the USB. Nouveau firmware does not install an NVIDIA
proprietary driver. The installed APT sources are:

| Vendor | Packages |
| --- | --- |
| NVIDIA | CUDA Debian repository mapped to Debian 13 for forky/sid |
| AMD | ROCm Core Debian 13 stable repository for forky/sid |
| Intel | oneAPI APT repository |

Packages from these vendors are given APT **pin priority 100** to
avoid replacing Debian versions automatically. The target OS,
kernel, GPU and vendor repository dependency compatibility remain
the user's responsibility. Forky is not necessarily vendor-qualified
for those Debian 13 repositories.

Source files: `/etc/apt/sources.list.d/devoid-*.sources` and
`/etc/apt/preferences.d/devoid-compute`. To avoid moving stored
Wi-Fi credentials off the host, review the source block that copies
`/etc/NetworkManager/system-connections/` **before** running.

## Upgrades and diagnostics

The script diverts Debian's conventional dracut hook and installs
`kernel-install` post-install/remove hooks, setting `BOOT_ROOT=/boot/efi`.
An APT post-invoke hook refreshes the fallback bootloader using
`bootctl --no-variables update`. Regenerate UKIs with
`kernel-install add-all` when troubleshooting after making deliberate
config changes.

Verify `findmnt /boot/efi`, `lsblk -f` and the `*.efi` files under
`/boot/efi/EFI/Linux/`. This variant is **not** a replacement for
the secured installer's owner key trust and recovery procedures.
