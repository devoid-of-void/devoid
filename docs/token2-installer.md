# Selectable Secure Boot signing

The secured installer offers `yubikey-piv` (default) and `token2-openpgp`
before partitioning. This branch integrates the previously tested
[Token2 signing chain](token2-openpgp-secure-boot.md) into the installer.
The USB installer is unchanged.

| Choice | Existing identity | PIN handling |
| --- | --- | --- |
| YubiKey PIV | Slot 9c, PKCS#11 object ID `02`, on-token X.509 certificate | PIV PIN in the root session keyring |
| Token2 OpenPGP | RSA-2048 authentication key in `OPENPGP.3`; certificate discovered or created automatically | OpenPGP User PIN through root's GnuPG agent and terminal pinentry |

Provision the signing key before installation. Token2 needs an existing
RSA-2048 key in `OPENPGP.3`; the installer does not generate, overwrite or
reset card keys. No certificate pathname or manual GPGSM procedure is needed.

Before partitioning, the installer discovers the authentication keygrip and
looks for matching X.509 certificates in the invoking root account's GPGSM
home (`GNUPGHOME`, or `$HOME/.gnupg`). It reuses the first matching certificate
that is not expired, in GPGSM listing order. It does not search other users'
homes or copy their GnuPG directories. If there is no usable certificate,
it creates a self-signed one using the existing card key, with subject
`CN=devoid Secure Boot`, SHA-256, random serial and a ten-year validity period
(configurable via `DEFAULT_SIGNING_CERTIFICATE_YEARS`). GPGSM's batch
`Key-Grip` parameter selects the existing key; a missing or ambiguous
`OPENPGP.3` key stops the installer before certificate creation or disk erasure.

The certificate is prepared in the temporary root GnuPG home used by the
card probe. Certificate creation may prompt for the OpenPGP User PIN and any
configured authentication-slot touch confirmation. Only the public certificate
is transferred into the target's dedicated root store; no key bytes are copied.
The existing signing-challenge check verifies the certificate/key pair before
kernel signing hooks and firmware enrollment. Preserve the installed public
certificate for later reuse; a newly generated certificate is not necessarily
byte-identical to one enrolled during an earlier installation.

FIDO2 enrollment for root encryption, PAM and homed remains separate from
signing. A configured FIDO2 credential/PIN is still required with either
choice. The supported USB checks are `1050:0407` for YubiKey and `349e:0014`
for the tested Token2 Mini. Only the signing backend is selectable; this
is not arbitrary-token discovery.

## Installed configuration

- `/etc/kernel/scripts/signing-exec` wraps all signing consumers: UKI
  generation, DKMS `sign-file`, fallback loader and PK authenticated update.
- `/etc/kernel/keys/openssl-signing.cnf` activates the default and PKCS#11
  providers only for wrapped commands. There is no global OpenSSL edit.
- Token2 uses `/etc/kernel/keys/gnupg`, owned by root with mode 0700. The
  installer discovers the card and imports the automatically prepared certificate.
  GnuPG PIN caching is disabled in this dedicated home; physical touch
  enforcement still depends on the token, and is **not established** by this
  integration. OpenPGP and FIDO2 PINs are distinct.
- Scute is managed by `p11-kit-proxy.so`, not loaded directly by OpenSSL.
  `/etc/kernel/keys/pkcs11` contains the Scute-only configuration.
- Every Token2 signing command starts a private mount namespace with
  `unshare --mount --propagation private`. Within that namespace, the wrapper
  bind-mounts this configuration over Debian's `/etc/pkcs11` and
  `/usr/share/p11-kit/modules`. This works for root without relying on
  per-user p11-kit configuration and leaves other programs' module lists
  unchanged. Mount or namespace failures stop signing.
- Token2 uses scdaemon's direct USB CCID driver, as in the successful hardware
  experiment. The live host's `pcscd.socket` and `pcscd.service` are stopped
  during installation; units that were active on entry are restarted during
  cleanup. A fresh temporary GnuPG home probes card access **before disk
  erasure**, then its agent is stopped to release the card for the container.
  A different GnuPG agent holding the card must release it before installation.
- The Token2 container receives USB device-cgroup access as well as the USB
  bind mount. It does not require the host PC/SC socket. The PIV backend still
  uses the PC/SC socket and installs `pcscd` in the target.
- In the installed system, `99-devoid-token2-ccid.rules` sets
  `PCSCLITE_IGNORE=1` for USB `349e:0014`. This reserves that model's CCID
  interface for scdaemon while leaving other PC/SC readers and FIDO2 available.
  The rule takes effect on boot/device discovery; pcsc-lite 2.3.2 or newer
  supports it (including the targeted Debian forky/sid packages).
  See the [PC/SC maintainer's explanation](https://blog.apdu.fr/posts/2025/04/ignore-readers-using-pcsclite_ignore-udev-property/).
  No host udev rules or global PC/SC masks are installed.
- The dedicated target agent is stopped when target configuration exits.
  It is started again on demand after boot. Use an interactive root terminal
  for signing and package updates; unattended PIN entry is not implemented.

The target phase rejects empty or multiple private-key URIs. It loads the
selected key, signs a random challenge and verifies it against the prepared
certificate **before installing the kernel signing hooks**. This occurs
**after disk partitioning and Debian bootstrap**, not before disk erasure.
The fallback EFI signature is also verified before firmware enrollment.
Signing failures propagate; there is no software-key or unsigned fallback.

## Verification and recovery test plan

Checks using temporary files and mocked card access (no installation or token operations):

```sh
bash -n devoid.sh
bash -n devoid-usb.sh
python3 -m unittest discover -s tests -v
```

The suite also includes a real GPGSM batch certificate-generation/reuse test
with a temporary software key. It is skipped where Unix sockets are prohibited
and gpg-agent cannot run. Mocked tests cover certificate reuse, generation
parameters and refusing a missing authentication key.

Before relying on this integration, test both backend choices on expendable
hardware with firmware recovery available. The earlier Token2 experiment
verified `sbsign`/`sbverify`; it did not verify this installer, systemd-sbsign,
DKMS, direct CCID-in-nspawn, or physical-touch enforcement.

1. Try an absent or inaccessible card. Confirm the host probe fails before
   partitioning and restores previously active PC/SC units. Then try a wrong
   certificate and cancelled PIN: the target phase must fail before kernel
   installation/firmware enrollment. Check
   OpenPGP retry counters; do not repeatedly guess a PIN.
2. With the correct identity, confirm challenge verification, signed fallback
   and UKI verification, then boot with Secure Boot enabled. Verify db, KEK,
   PK and the service-driver hash entries using the existing installation plan.
3. Reboot and update/reinstall a kernel from an interactive root terminal.
   Confirm UKI signing prompts work with a fresh agent. Rebuild the DKMS test
   module, inspect its signer and verify the kernel accepts it under lockdown.
4. Confirm unrelated root OpenSSL/p11-kit consumers retain their original
   configuration. Remove the card and confirm updates fail rather than
   generating unsigned replacements. Check signing failure exit statuses.
5. Verify FIDO2, recovery-passphrase and TPM root unlock independently; repeat
   root PAM and homed checks. Test firmware key recovery and replacement of a
   lost signing identity using [RECOVERY.md](RECOVERY.md). The LUKS recovery
   passphrase cannot recreate either PIV or OpenPGP signing keys.

Manual signing commands on the installed system must use the wrapper, e.g.
from a **ROOT** terminal:

```sh
/etc/kernel/scripts/signing-exec openssl list -providers
/etc/kernel/scripts/signing-exec pkcs11-tool \
  --module /usr/lib/x86_64-linux-gnu/p11-kit-proxy.so --list-objects
```

The second command is for the Token2 backend. To change backend on an existing
installation requires explicit certificate/trust migration; changing the
source default does not migrate an installed system.

## Card-discovery failure in the first integration

The initial commit forced `disable-ccid` and failed at `gpg --card-status`
inside nspawn with `No such device`. A fresh GnuPG home on the live host,
with PC/SC stopped, successfully read the Token2 OpenPGP application and its
existing authentication key on 1 November 2026. The corrected integration
therefore uses direct CCID. That host probe confirms card availability;
it does not by itself validate container access or subsequent signing.

Do not restart a failed installation merely to test card access: the normal
entry point partitions the disk again. The target phase is also not a general
resume mechanism; it includes non-idempotent setup operations.
