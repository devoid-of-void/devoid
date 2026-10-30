# Recovery and break-glass procedures

**Keep a copy of this document off the machine.** The most valuable
recovery asset is the independent **root LUKS2 passphrase**. The TPM and
security key can stop working because of firmware changes, token reset,
damaged hardware or keyslot corruption. A separate backup of the
encrypted disk is still essential.

**Never run** `luksFormat`, `mkfs.xfs`, `wipefs`,
`systemd-cryptenroll --wipe-slot=...` or `sgdisk --zap-all` on a volume
you are trying to recover. First work from a copy when there is any
evidence of disk or LUKS-header damage.

All example commands are **ROOT** commands without `sudo`.

## 1. Rescue the root filesystem with the recovery passphrase

Boot a trusted Linux rescue environment that provides `cryptsetup`,
`lsblk` and XFS support. On a machine whose owner Secure Boot policy
prevents the rescue USB from booting, first use a **known-safe firmware
recovery procedure** or remove the encrypted disk for use in a
different trusted computer.

Identify the partition by its size and `crypto_LUKS` type, **not**
by guessing a drive letter:

```sh
lsblk -o NAME,PATH,TYPE,SIZE,FSTYPE,UUID,PARTUUID,MOUNTPOINTS
```

Set `ROOT_LUKS` to that partition's actual path (the value below
is a placeholder):

```sh
ROOT_LUKS=/dev/disk/by-partuuid/YOUR-ROOT-PARTUUID
cryptsetup isLuks --type luks2 "$ROOT_LUKS"
cryptsetup luksDump "$ROOT_LUKS"
```

To unlock with the **independent passphrase**, not FIDO2 or TPM:

```sh
cryptsetup open --type luks2 "$ROOT_LUKS" devoid-rescue
```

Enter the original LUKS2 passphrase. The mapper appears at
`/dev/mapper/devoid-rescue`. For read-only inspection:

```sh
mkdir -p /mnt/devoid-rescue
mount -t xfs -o ro /dev/mapper/devoid-rescue /mnt/devoid-rescue
ls -la /mnt/devoid-rescue
```

If XFS reports a log-recovery problem, **do not attempt random repairs**.
Use a full disk copy and consult `xfs_repair` documentation. There is a
read-only `norecovery` mount option for controlled inspection, but it
can show an inconsistent filesystem; it is not a general data-repair
solution.

Copy out essential files to separate storage. To close safely:

```sh
umount /mnt/devoid-rescue
cryptsetup close devoid-rescue
```

Keep filesystems unmounted before closing their device mapper.

## 2. TPM auto-unlock fails after Secure Boot changes

This is an expected possible consequence of the PCR 7 policy. Try
the FIDO2 unlock path or enter the independent recovery passphrase.
The installer also generates an on-system re-enrollment script:

```sh
/root/tpm-enroll.sh
```

Run that **only after you have successfully booted the intended,
owner-trusted UKI**, verified the firmware state, and are satisfied
that the new PCR measurement should be trusted. It wipes/replaces
the previous TPM token; do not re-enroll blindly after a suspected
compromise. Keep another working LUKS unlock method.

## 3. Lost YubiKey or unusable PIV signing key

**Root data:** the LUKS recovery passphrase should still unlock the
volume using the procedure above if the LUKS header and data are
intact. The PIV signing key and root LUKS passphrase are different.

**Trusted boot and updates:** if the PIV signing key is truly lost
and nonexportable, you cannot simply re-sign a UKI with the old
identity. You need a previously provisioned backup signing identity
trusted by your firmware, or a carefully planned firmware Setup Mode
recovery and enrollment of a new owner's trust chain. The installer
does not automate key rotation, backups of on-token signing keys,
or restoration of a failed Secure Boot enrollment.

Do not erase the only working recovery keyslot to make experiments
with another hardware token.

## 4. Firmware Secure Boot changes or a nonbooting UKI

Before altering Secure Boot variables:

- Verify the disk itself and root data are still recoverable via
  the manual passphrase procedure.
- Check whether the fallback loader
  (`EFI/BOOT/BOOTX64.EFI`) and signed UKIs in `EFI/Linux/` exist
  and their signatures match the enrolled owner's certificate.
- Review firmware's `SetupMode`, `SecureBoot`, `db`/`KEK`/`PK`
  state; compare with your preinstall record.
- Use the motherboard's actual recovery flow to restore trust
  if necessary. Firmware-specific steps are intentionally not
  guessed here: writes to `PK`/`KEK`/`db` are dangerous.

Changing boot entries alone will not fix a missing or invalid
Secure Boot trust anchor. Also remember that `devoid.sh` deletes
most existing firmware boot entries, so unrelated OS entries may
need manual restoration afterwards.

## 5. Optional homed user recovery

The `create_homed_user.sh` helper creates LUKS-backed **ext4** home
storage with an **independent homed recovery key**, *not* the root
LUKS2 passphrase. Recover the root first, preserve the home image,
then inspect its identity/metadata through `homectl` on a compatible
system. Avoid rewriting homed identity or recreating a user with
the same name before the original home is backed up.

A `systemd-homed` image is not the same as a conventional directory
under an unencrypted `/home`; keep both its storage and recovery
material.

## 6. After recovery

Make **another backup** before changing any LUKS token, Secure Boot
variable or on-disk partition. Document exactly which key works,
which boot image signed it, and which measured firmware state you
intend to trust. Repeat verified boot and TPM, FIDO2 and recovery
unlock tests separately.
