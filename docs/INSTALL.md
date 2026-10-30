# Secured installation and first boot

> **Destructive and firmware-changing.** The current `devoid.sh` erases its selected disk, writes Secure Boot `db`, `KEK` and `PK`, and removes almost all existing UEFI boot entries. It may leave the machine unable to boot. Use expendable hardware, independently verified backups and a firmware recovery plan.

This guide describes the `progressive-refactor` branch, not a universal installer. Commands shown are for a **ROOT** shell (prompt `#`). No `sudo` is required.

## 1. Prepare independent recovery paths

Before starting, back up all data and confirm that the backup restores on another machine. Record the firmware Secure Boot state, existing `PK`/`KEK`/`db`/`dbx`, and boot entries if your firmware permits; learn how to restore factory keys or enter recovery mode. Changing Secure Boot keys can prevent other operating systems, option ROMs and installation media from booting.

Provision a supported YubiKey with a **PIV slot 9c** signing key and certificate (PKCS#11 object ID `02`), signing PIN, and token-enforced touch confirmation. Configure its FIDO2 PIN as well. PIV and FIDO2 are separate key applications with different PIN domains. The current code checks USB ID `1050:0407`: other keys are not supported without changing the installer and validating the PKCS#11 stack.

Plan to record two independent secrets: the **root LUKS2 recovery passphrase** and the generated **root password**. If you later create a `systemd-homed` user, it has a *third*, separate recovery key. The Secure Boot signing private key is intended to be nonexportable; loss of the token can make future signed kernel updates impossible without an alternative trust-recovery plan.

## 2. Boot the live environment

Use a Debian-based **UEFI** live environment, with network access and working Debian package repositories. The script installs packages on the live host, starts `pcscd`, and later runs privileged target configuration under `systemd-nspawn`.

Check prerequisites as **ROOT**:

```sh
test -d /sys/firmware/efi/efivars && echo UEFI
test -c /dev/tpmrm0 && echo TPM2
test -r /sys/kernel/security/tpm0/binary_bios_measurements && echo TPM-event-log
lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,MOUNTPOINTS
ls -l /dev/disk/by-id/
```

Install `usbutils` on the live host if `lsusb` is missing, since the script uses it to detect the key:

```sh
lsusb -d 1050:0407
```

For firmware already in Setup Mode, the data byte after the four UEFI variable attribute bytes should be `1`:

```sh
od -An -t u1 -j4 -N1 \
  /sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c
```

Do **not** remove firmware keys unless you know how to recover the machine. The installer itself expects Setup Mode; it does not perform a portable, safe transition into Setup Mode.

## 3. Review source defaults and select the disk

The main installer does not take the target disk as a command-line argument. Inspect the `DEFAULT_*` block:

```sh
grep -n '^readonly DEFAULT_' ./devoid.sh
```

**Replace `DEFAULT_DISK`**; the checked-in value names a specific real Kingston drive. Use a stable `/dev/disk/by-id/` identifier, and validate it against the actual device and serial:

```sh
readlink -f /dev/disk/by-id/YOUR-DEVICE
lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,MOUNTPOINTS
```

The current defaults are Debian `forky`, 10 GiB ESP, 8 GiB swapfile, TPM PCR `7`, 100 GiB homed image, hostname `devoid-forky`, Zsh theme `risto`, and Plymouth theme `solar`. They are source constants, not command-line options.

Unlike the USB variant, the secure installer does **not** implement a complete protective check against selecting the live system's root disk. An incorrect choice is catastrophic.

## 4. Run the installer

From the directory containing `devoid.sh`, as **ROOT**:

```sh
bash ./devoid.sh
```

Follow disk, hostname, LUKS, FIDO2 and PIV prompts. Be ready for repeated PIN entry and physical touches. The installer creates the GPT, FAT32 ESP, LUKS2 root and XFS filesystem; installs Debian via `mmdebstrap`; then configures boot/signing/PAM via `systemd-nspawn`.

The target phase signs UKIs and fallback bootloader, prepares module-signing hooks, extracts SHA-256 digests of measured EFI service drivers from the **live host's** TPM event log, and enrolls the owner's Secure Boot certificate and driver digests. It updates `db` and `KEK` before `PK` (last). The host phase then deletes almost all current firmware boot entries (preserving only entries containing “debugging”) and installs a new one.

There is no transaction or reliable rollback for firmware operations. It may also copy **NetworkManager profiles and credentials** from the live host to the target. See [security](SECURITY.md).

## 5. First boot and TPM enrollment

Boot the new Debian system with Secure Boot enabled. Keep the YubiKey **and the independent LUKS recovery passphrase** available.

Run the generated helper as **ROOT**:

```sh
/root/tpm-enroll.sh
```

It re-enrolls the TPM2 keyslot using `--tpm2-pcrs=7` and FIDO2 unlocking after the installed system has booted. The first TPM enrollment made in the live environment is not the final policy. Do not rely on TPM auto-unlock until you have tested it.

## Post-install verification

Check all critical paths independently, before storing valuable data:

- `mokutil --sb-state`, firmware owner's `PK`/`KEK`/`db`, and signatures on the installed `.efi` images (for example `sbverify --list`).
- Expected UKIs in `/boot/efi/EFI/Linux/` and the signed fallback `/boot/efi/EFI/BOOT/BOOTX64.EFI`.
- `findmnt / /boot/efi`, `lsblk -f` and `swapon --show`.
- Root unlocking by TPM, FIDO2 **and** the recovery passphrase, with a working rescue plan.
- PAM login and both `su` and `su -` using the YubiKey (PIN and touch), and the preserved root password fallback.
- DKMS module signing after a kernel change; firmware and provider compatibility are not guaranteed by a syntax check.

## Optional encrypted home

As **ROOT**:

```sh
/root/create_homed_user.sh USERNAME
```

The helper enables `systemd-homed`, creates a 100 GiB LUKS-backed **ext4** home, requires FIDO2 PIN/presence and generates a separate recovery key. Preserve that key.

A desktop is not installed by default. Select one afterwards with `tasksel` or Debian packages, then validate boot again.

For break-glass recovery, see [RECOVERY.md](RECOVERY.md).
