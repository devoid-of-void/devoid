# Development and verification

The `progressive-refactor` branch is an incremental cleanup of the
original, deliberately single-file, two-phase secure installer.
Maintain the security architecture and avoid “convenience” refactors
that silently remove Secure Boot key management, FIDO2/TPM unlocking,
DKMS signing, boot-entry behavior or homed support.

## Working conventions

- Keep logical changes focused; inspect the diff before proceeding to
  another feature. Prefer small reviewable commits.
- Keep user-tunable values in the top `DEFAULT_*` block and internal
  paths/identifiers in the constants block. `KEYS_DIR` is
  `/etc/kernel/keys`.
- Preserve the host/target boundary. The main script is installed and
  invoked within `systemd-nspawn` as `/devoid.sh target ROOT_PARTITION`.
- Prefer safe validation, failure propagation, scope-limited secrets,
  proper cleanup and verifiable boot output. **Do not** relax
  authorization or store signing keys unencrypted on disk.
- All administrative documentation commands are for **ROOT**; do
  not prefix them with `sudo`.
- Any alteration to firmware `PK`/`KEK`/`db`, driver hashes,
  kernel signing or LUKS keyslots needs a dedicated recovery test
  plan and review against [SECURITY.md](SECURITY.md).

## Useful static checks

From the repository directory (USER or ROOT; no disk touched):

```sh
bash -n devoid.sh
bash -n devoid-usb.sh
```

If ShellCheck is installed:

```sh
shellcheck devoid.sh devoid-usb.sh
```

Static analysis cannot prove that firmware enrollment, signing-provider
loading, PKCS#11 touch rules or TPM measured state are correct. Do
not call a feature hardware-tested merely because the shell parses.

## Tests that cannot be replaced by lint

On disposable hardware, verify: correct disk selection and abort paths;
firmware Setup Mode transition; `db`/`KEK`/`PK` enrollment including
EFI service-driver hashes; signed UKI and fallback boot with Secure
Boot enabled; FIDO2/passphrase/TPM root unlock; re-enrollment after
boot; root PAM U2F `su`, `su-l` and `login`; DKMS rebuild/signing after
a kernel upgrade; homed creation/recovery; failure cleanup; and the
USB variant's generic-initramfs boot on more than one computer.

### Current caveats for future work

- Full end-to-end motherboard/firmware test coverage is incomplete.
- The main secure installer currently checks a fixed YubiKey USB ID,
  hardcodes several provider and HID paths, and has an unsafe
  machine-specific default disk. These are **not** portability promises.
- Installing the PK last is intentional, but transactionality and
  firmware recovery are not implemented.
- The OpenPGP/Scute Token2 signing guide is a tested EFI proof of
  concept, **not yet merged into the main PIV/UKI/DKMS implementation**.
- A long-term goal is safer key lifecycle/recovery and improved
  testability **without weakening** the trust design.

See [ARCHITECTURE.md](ARCHITECTURE.md) for a component-level map,
[INSTALL.md](INSTALL.md) for installation and [RECOVERY.md](RECOVERY.md)
before experimenting.
