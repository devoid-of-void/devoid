# An alternative devoid

`devoid-alternative.sh` is a complete alternative to `devoid.sh`, based on
repository commit `90be31f`. The original installer and USB installer are unchanged.
This is an implementation for comparison, not a claim of a verified hardware installation.

Run it from an amd64 Debian live system with systemd, network access, a TPM 2.0,
and your configured YubiKey. The firmware must be in Setup Mode. It will ask
for a whole disk and require its path again before erasing it:

```sh
sudo bash ./devoid-alternative.sh
```

It uses the existing PIV slot 9c key/certificate. It does not generate a new key
or modify the YubiKey's touch policy. Use a key whose touch policy is already set
as you want it. The live system needs sufficiently recent systemd tools for the
credential-based FIDO2 enrollment used by the original installer.

## How I chose to structure it

The design still ships as a single file. The main host and target functions show
the sequence; functions contain the operations belonging to each stage. I would
start reading at `host_main`, then `target_main`.

Each function owns a stage, a reusable operation, or a lifecycle boundary. That
includes some functions called once: their purpose is to let the reader consider
one responsibility at a time and to give tests an entry point. It costs navigation
between the sequence and its implementation. Your region-based version keeps more
of that sequence immediately visible; that is the principal stylistic tradeoff.

Local temporaries stay local. Shared host state consists of the disk/partition
identifiers, the working directory, and resource-ownership flags. The target receives
the LUKS UUID explicitly; it does not inherit the host's Bash variables.

Utility failures retain their own diagnostics. A small trap adds the current stage
and line, releases resources this invocation acquired, and preserves a failing exit
status. It deliberately does not echo failing commands, which can contain secrets.
This is cleanup rather than rollback: disk and firmware changes are not undone.

## What stays the same

- Debian Forky, a 2 GiB FAT ESP, and XFS inside the remaining LUKS2 partition.
- A recovery passphrase, FIDO2 enrollment, and provisional PCR-7 TPM enrollment.
- Root's generated recovery password and FIDO2 PAM login/su authentication.
- Zsh, Oh My Zsh, and the risto theme.
- YubiKey PIV signing of UKIs, fallback bootloader, and DKMS modules.
- Dracut, UKI generation, the signed `fbx64.efi` fallback, and UTF-16LE boot hints.
- Owner certificate in db and KEK; owner PK enrolled last. No Microsoft CA is added.
- The original firmware-boot-entry policy: remove entries except those whose text
  contains `debugging`, and set the installed entry as BootOrder and BootNext.
- NetworkManager profiles, maintenance tools, 8 GiB swap, TPM resealing helper,
  and the FIDO2-backed systemd-homed user helper.
- Desktop selection remains an explicit post-install `tasksel` operation.

## Consequential differences

| Area | Alternative behavior and reason |
| --- | --- |
| Disk selection | No embedded hardware-specific disk ID. Checks whole-disk type, mounted descendants, swap and active block-device users, then asks for the exact path before erasure. |
| Resource lifetime | Host and container install separate traps. The container cannot accidentally execute host unmount/cryptsetup cleanup. A failed install cannot report success through unconditional `exit 0`. |
| Machine access | The host owns TPM enrollment, FIDO2 enrollment, boot entries and EFI variables. The container only receives PC/SC for signing, plus the read-only installer. No TPM, raw disk, USB, hidraw or efivarfs passthrough is required. |
| Driver trust | Before erasing the disk, parse the current TPM log with Debian's jq-based `yq`, select PCR-2 SHA-256 `SERVICES_DRIVER` events, deduplicate, and package raw digests using `sbsiglist`. Append that ESL to db before PK. Preserve log and hashes in `/etc/kernel/keys`. |
| Unlocking | Kernel options request `fido2-device=auto`, matching the enrollment, rather than the original `pkcs11-uri=auto`. The initial TPM token is still provisional. |
| Credentials | `pamu2fcfg` handles its own interactive PIN prompt. No PIN interpolation into Tcl/Expect. PIV PIN enters keyctl through stdin and OpenSC through an environment reference. It is still present in signing-process environments while needed. |
| Signing configuration | A dedicated OpenSSL configuration is exported by signing helpers rather than appended to the system-wide OpenSSL configuration. UKI signing uses the provider; efitools' `-e pkcs11` uses the libp11 engine. |
| DKMS | Uses the current four-argument `sign_file` interface. The helper reads the module's target kernel from vermagic, avoiding reliance on an unexported `kernelver` variable or the live kernel's version. |
| Generated hooks | Strict mode and separate assignment/export propagate PIN-helper failure. Missing cached PIN is an expected branch, not an installer failure. |
| Boot images | Configure the Plymouth theme before generating the first UKI. Verify fallback and UKI signatures with `sbverify` before firmware enrollment. |
| Firmware commit | Prepare `PK.auth` in the container, complete target configuration and boot-entry creation, then write db, append drivers, write KEK, and write PK on the host. A preceding failure stops before PK. |
| Package management | Uses `apt-get`, removes incidental `--autoremove --purge`, adds the package supplying `systemd-sbsign`, and drops `tpm2-tss`, `network-manager-tui` and `netctl` from the Debian package list. `nmtui` is supplied by NetworkManager. |
| Updates and networking | Explicitly enable NetworkManager, resolved and homed; mask APT's automatic-update timers so package changes remain deliberate. |
| Shell installation | Retains the upstream Oh My Zsh installer, but download and execution are separate commands so a failed download stops. It remains an unpinned upstream dependency, as in the original. |

The original signing-related Debian sysusers workaround and dracut post-install
diversion are retained. This rewrite is not a redesign of your boot chain or a
general-purpose installer framework. It is not resumable or idempotent.

## After installation

Enable Secure Boot in firmware and boot the installed system. Use FIDO2 or the
recovery passphrase for the first unlock. Run `/root/tpm-enroll.sh` to replace
the provisional TPM token with one bound to PCR 7 in the installed boot state.
That helper checks that Secure Boot is enabled before resealing.

Driver hashes authorize the exact images measured on the installer boot. The
allowlist does not discover drivers that were not loaded, and firmware/option-ROM
updates can change those hashes. A system with no matching SHA-256 driver events
stops before disk erasure rather than treating an empty allowlist as success.
The hardware-dependent completeness of this allowlist remains to be checked on
your machine.

## Validation

```sh
bash -n devoid-alternative.sh
shellcheck devoid-alternative.sh
python3 tests/test_alternative.py
```

The tests source the installer without starting it and mock machine operations.
They cover firmware order, stopping before PK on a failed db append or Setup Mode
check, cleanup ownership/order/status, absence of command secrets in trap output,
generated-script syntax, and driver-event selection. The optional binary-format
test runs real `xxd` and `sbsiglist` and checks the resulting SHA-256 ESL layout.
Install Debian's `yq`, `sbsigntool` and `xxd` to run all tests without skips.

These checks do not validate a real installation, firmware writes, a YubiKey signing
session, DKMS signing on the target kernel, or reboot/unlock behavior. Forky package
resolution and installed hook interactions still need an installation trial. The
script prints completion only after its commands succeed, but tools such as DKMS
can report some signing problems as warnings; inspect the installed module signer
during the hardware trial as well.

Implementation references consulted:

- [systemd-cryptenroll](https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html)
- [systemd-sbsign](https://www.freedesktop.org/software/systemd/man/latest/systemd-sbsign.html)
- [DKMS source](https://github.com/dell/dkms/blob/main/dkms.in)
- [OpenSC pkcs11-tool source](https://github.com/OpenSC/OpenSC/blob/master/src/tools/pkcs11-tool.c)
- [libp11 configuration](https://github.com/OpenSC/libp11)
- [yq](https://kislyuk.github.io/yq/)
