# Security model and hazards

**This is an experimental, destructive installer, not a security certification.**
No claim of immunity from firmware compromise, physical coercion, malware
running after unlock, an already-compromised owner key, or state-level actors
is made. It is intended to harden a *powered-off* Debian machine under a
specific owner-controlled signing and encryption arrangement.

## What each mechanism actually provides

| Component | Intended protection | Does *not* establish |
| --- | --- | --- |
| Owner Secure Boot `PK`, `KEK` and `db` | Firmware loads images trusted by the owner's key policy | Safety of trusted images or invulnerability of firmware |
| Signed UKIs | Signed kernel, initramfs and command line are in one bootable image | Integrity of arbitrary user-space files or protection after boot |
| YubiKey PIV signing key | Signing authority stays on-token; PIN/touch can gate its use | Protection if a token accepts PIN-only signing or a trusted signer is malicious |
| LUKS2 encrypted root | Confidentiality at rest when locked, subject to passphrase/key security | Confidentiality after mounting or authentication of all disk sectors |
| TPM2 policy on PCR 7 | Auto-unlock bound to measured Secure Boot state | Complete filesystem measurement; guaranteed protection if firmware is broken |
| FIDO2 enrollment | Additional physical-token root unlock method | Recovery from a lost/reset token without separate passphrase |
| `systemd-homed` image | Independent at-rest home encryption and recovery key | Protection while home is active and readable by a compromised session |
| PAM U2F | Convenient token-based login for root authentication paths | Mandatory token-only root login: password fallback remains enabled |

The installation generates a 12-character root password and displays it on the
console. Protect and, where needed, rotate it. PIV PINs may be held temporarily
in a root session keyring, and normal command/runtime memory remains exposed
to the privileged host. A signing PIN is not the same as a FIDO2 PIN.

The TPM event log's driver digests are **measurements**, not independent
proof that the corresponding firmware drivers are safe. Appending those
hashes to `db` authorizes matching unsigned firmware drivers. Review the
exact driver digests and understand the implications before enrollment.

## Firmware and disk changes that can strand the machine

**The main installer changes more than the selected disk:**

1. `sgdisk --zap-all` destroys the chosen disk's GPT. The source contains
   a **real hardware by-id value** for `DEFAULT_DISK` and lacks a robust
   check preventing the live root disk from being selected.
2. It replaces Secure Boot `db`, enrolls an additional list of measured
   EFI service-driver hashes, changes `KEK`, and finally enrolls `PK`.
   After `PK` is installed, further updates require authorized signatures
   or a deliberate firmware recovery procedure.
3. It deletes nearly every existing `Boot####` firmware entry, excluding
   entries whose text contains “debugging”, then creates its own.
4. Clearing firmware keys to enter Setup Mode can prevent trusted
   external boot media, option ROMs and existing operating systems from
   starting. Firmware bugs can make recovery unusually difficult.
5. The nspawn target is privileged and receives TPM, USB, PC/SC, raw
   device and efivarfs bindings. This is not an isolation boundary.
6. The installer modifies the live environment (APT packages,
   `pcscd`). It copies live-host NetworkManager connection profiles
   into the target, potentially including secrets. It downloads and
   executes Oh My Zsh's install script inside the target.
7. Kernel and DKMS update hooks may request a signing PIN/key. If the
   token is unavailable or OpenSSL/PKCS#11 compatibility changes,
   updates or boot artifacts may fail to be generated.

For these reasons, prepare **verified backups** and an independent way to
restore firmware settings and/or recover files, *before* installation.

## Boot and authentication are distinct trust boundaries

The security chain relies on correctly configured firmware, the right
certificate in the firmware database, correctly signed UKIs/modules,
correct keyslot enrollment, TPM state and available unlock secrets.
A failure in any link is not automatically recoverable by the installer.

`DEFAULT_TPM_PCRS="7"` ties automatic root unlock to the Secure Boot policy.
A firmware configuration change might trigger the FIDO2/passphrase fallback.
PCR 7 alone cannot detect arbitrary malicious changes to files in the
installed root filesystem.

The `pam_u2f.so` rules are prepended as `auth sufficient` to `su`,
`su-l` and `login`, while distribution PAM defaults remain. Authentication
by the generated root password may still succeed through those defaults;
do **not** describe this as two-factor enforcement for every root session.

Secure Boot prevents execution of *untrusted boot binaries* according to
firmware policy. It does not prevent the authorized user from installing
untrusted applications or protect the integrity of an already-running root
session. Backups, package provenance and sensible administrative practice
remain necessary.

## Signing-provider configuration

The main script writes a specific PKCS#11-capable OpenSSL configuration at
`/etc/kernel/keys/openssl-signing.cnf`, which its signing helpers use
locally. **Do not export that configuration globally** in the login
environment: unrelated OpenSSL consumers, including Node/Codex, may fail
or behave unexpectedly when the expected provider/PIN environment is
missing.

The current YubiKey PIV integration and the [Token2 OpenPGP/Scute
experiment](token2-openpgp-secure-boot.md) are distinct. An EFI signing
proof of concept with Token2 does not validate production UKI, DKMS,
firmware enrollment or recovery on this branch.

## Safe validation and reporting

On a nonproduction machine, test separately: a fresh successful
signed boot, PCR changes that should prevent TPM auto-unlock,
independent FIDO2/passphrase recovery, every PAM authentication
path, UKI regeneration after updates, DKMS signing, and firmware
recovery. Keep root LUKS and homed recovery credentials offline.

Never publish PINs, passphrases, recovery keys or private NetworkManager
connections. Disk serials and token identifiers in logs are also
potentially identifying. See [RECOVERY.md](RECOVERY.md) for manual
access to encrypted data.
