# devoid

**d**evoid — a deliberately opinionated Debian installer.

> **Danger: destructive, experimental, and hardware-specific.** The primary installer
> wipes the selected disk, replaces Secure Boot trust databases, and deletes most
> existing UEFI boot entries. It can leave the machine unable to boot. This is
> not a general-purpose Debian installer or a production deployment recipe.
> Read [the installation guide](docs/INSTALL.md) and [the risks](docs/SECURITY.md)
> **before** touching a disk or firmware setting.

devoid exists because its author has used Debian since 1999 and wanted a machine
configured *exactly* to his liking, without spending another decade accepting
defaults or maintaining a forest of just-in-case options. It is published as
an experiment and a reference for experienced Linux users, not as a replacement
for the official Debian installer.

There are **two deliberately different installers**:

| | `devoid.sh` — secured installation | `devoid-usb.sh` — portable USB |
| --- | --- | --- |
| Purpose | Owner-controlled, hardware-bound Debian system | Portable, conventional Debian on USB |
| Root | LUKS2-encrypted XFS | Unencrypted XFS |
| EFI system partition | 10 GiB (current default) | 2 GiB (current default) |
| Boot | Signed UKIs and signed fallback loader | Unsigned UKIs and systemd-boot |
| Authentication | FIDO2, recovery passphrase, TPM2 | Password |
| Firmware | Installs its own Secure Boot db/KEK/PK; rewrites boot entries | Does not enroll keys or change NVRAM boot entries |
| Intended hardware | Specific YubiKey PIV/FIDO2 + TPM2 + UEFI setup | Bootable USB target, UEFI |
| Extras | systemd-homed helper, DKMS signing hook | Generic initramfs, firmware and optional compute repositories |

**Do not use the USB variant as though it provided the security properties of
the primary installer.** [USB guide](docs/USB.md).

## How the secured installation works

```text
UEFI firmware in Setup Mode
  ├─ owner-controlled Secure Boot db / KEK / PK
  │    ├─ signing certificate stored in db
  │    └─ selected measured EFI service-driver SHA-256 hashes in db
  └─ signed fallback loader → signed unified kernel image (UKI)
                                 ├─ kernel + dracut initramfs + cmdline
                                 └─ LUKS2 root (XFS)
                                      ├─ independent recovery passphrase
                                      ├─ YubiKey FIDO2 token
                                      └─ TPM2 token (PCR 7)
                                           └─ /home: optional homed LUKS images
```

UKI and DKMS signing use a private key held in a **YubiKey PIV slot 9c**
(PKCS#11 object ID `02`), with a PIV PIN and touch policy controlled by the
token. Root LUKS2 is enrolled for FIDO2 and TPM2 unlocking; a separate recovery
passphrase remains available. TPM enrollment is repeated **after first boot**
so PCR 7 reflects the installed boot environment. On the installed system,
`su`, `su -` and `login` are configured with an additional PAM U2F
authentication path. Root password authentication is also retained through
the distribution's PAM configuration; this is **not** a token-only login design.

The script also configures an XFS root, an 8 GiB **swapfile**,
a Plymouth theme, and a helper to create a 100 GiB
FIDO2-protected `systemd-homed` user image with its own recovery key.
No graphical desktop is selected automatically.

These are descriptions of what the **current branch code attempts to do**,
not a claim that every motherboard, firmware or token combination has been
tested. [Architecture](docs/ARCHITECTURE.md) ·
[Threat model](docs/SECURITY.md).

## Requirements for `devoid.sh`

- An expendable whole disk with independently verified backups. The
  `DEFAULT_DISK` in the source is a **real, machine-specific by-id path**;
  change it before running.
- A Debian-based live environment booted in **UEFI mode**, with working
  networking and package repositories. The host phase installs dependencies.
- Firmware that supports Secure Boot **Setup Mode**, writable EFI variables,
  and recovery from a failed owner-key enrollment. Removing existing keys
  or entering Setup Mode can make the system unbootable.
- A working TPM 2.0 exposed as `/dev/tpmrm0`.
- The **specific YubiKey model currently checked by the code**
  (USB ID `1050:0407`), with FIDO2 PIN and PIV slot 9c provisioned with
  a usable signing key and X.509 certificate; PIV PIN and touch policy set.
- Ability to recover the owner Secure Boot signing identity and independently
  unlock the root LUKS2 volume. See [Recovery](docs/RECOVERY.md).

Token2 OpenPGP signing via Scute is a **separately tested proof of concept**,
not integrated into this installer or a drop-in replacement for the PIV
requirement. [Token2 guide](docs/token2-openpgp-secure-boot.md).

## Installing (secured mode)

Read the [step-by-step guide](docs/INSTALL.md) first. In outline:

1. Back up data **and existing firmware keys/settings**, confirm a firmware
   recovery path, and inspect the selected disk by serial/by-id.
2. Provision/test the YubiKey's PIV and FIDO2 functions, enter firmware
   **Setup Mode**, boot a Debian live environment and connect to the network.
3. Edit the `DEFAULT_*` block at the top of `devoid.sh`, especially
   `DEFAULT_DISK` and `DEFAULT_DEBIAN_RELEASE`.
4. Run in a **ROOT** shell, from the directory containing `devoid.sh`:

   ```sh
   bash ./devoid.sh
   ```

5. Follow the prompts, preserve the LUKS recovery passphrase and root password,
   and be ready for multiple security-key PIN/touch prompts.
6. After booting the newly installed system with Secure Boot enabled, in a
   **ROOT** shell run:

   ```sh
   /root/tpm-enroll.sh
   ```

   This re-enrolls TPM2 against the booted environment. Keep the FIDO2 key and
   recovery passphrase available until you have verified TPM, FIDO2 **and**
   recovery unlocking independently.

To create a FIDO2-protected home for a new user, in a **ROOT** shell:

```sh
/root/create_homed_user.sh USERNAME
```

The helper requests a homed recovery key. Preserve it separately; it is
distinct from root's LUKS recovery passphrase. Install a desktop via
`tasksel` or the desired Debian packages after verifying basic boot.
See [post-install checks](docs/INSTALL.md#post-install-verification).

## Defaults worth reviewing

The current `progressive-refactor` branch defines these at the top of
`devoid.sh` (source of truth):

| Setting | Current value |
| --- | --- |
| `DEFAULT_DEBIAN_RELEASE` | `forky` |
| `DEFAULT_HOSTNAME` | `devoid-forky` |
| `DEFAULT_ESP_SIZE` | `10G` |
| `DEFAULT_SWAP_SIZE` | `8G` |
| `DEFAULT_HOMED_DISK_SIZE` | `100G` |
| `DEFAULT_TPM_PCRS` | `7` |
| `DEFAULT_ZSH_THEME` | `risto` |
| `DEFAULT_PLYMOUTH_THEME` | `solar` |

The disk default is intentionally **not** repeated here: the checked-in
value identifies a particular physical drive. Always inspect the script
and replace it. These are currently source constants, **not CLI flags**.

## Portable USB variant

For an ordinary Debian installation on a removable drive, use
`devoid-usb.sh`. It has **no LUKS2, hardware-key authentication or owner
Secure Boot enrollment**. It avoids firmware boot-entry changes and uses a
portable systemd-boot fallback. It also copies host NetworkManager connection
profiles, which **may contain Wi-Fi credentials**, to the USB device.

Run from a **ROOT** shell after checking the disk carefully:

```sh
bash ./devoid-usb.sh /dev/disk/by-id/usb-YOUR-DEVICE
```

A disk confirmation prompt is displayed before destruction. The script
refuses a disk containing the currently mounted root filesystem; that check
does **not** protect other important drives. See [USB installation](docs/USB.md).

## Documentation

- [Installation and first boot](docs/INSTALL.md)
- [Architecture and design decisions](docs/ARCHITECTURE.md)
- [Security boundaries and firmware hazards](docs/SECURITY.md)
- [Recovery: broken boot, missing key and LUKS access](docs/RECOVERY.md)
- [Portable USB variant](docs/USB.md)
- [Token2 OpenPGP-to-PKCS#11 signing experiment](docs/token2-openpgp-secure-boot.md)
- [Development and verification](docs/DEVELOPMENT.md)

## Scope and support

**Experimental**, single-purpose and intentionally non-portable. The
`progressive-refactor` branch is work in progress: inspect diffs, validate
each change on disposable hardware where possible, and do not interpret a
successful syntax check as a successful Secure Boot installation.

No guarantee is made against theft, coercion, firmware compromise, an
attacker with a running unlocked system, or user-installed malicious code.
**Backups and a rehearsed recovery procedure are mandatory.**

Licensed under [GPL-3.0](LICENSE).
