# Secure Boot signing with a Token2 OpenPGP key (without PIV)

A tested way to sign EFI binaries using a Token2 Mini's **OpenPGP** key through **PKCS#11**, **X.509**, and OpenSSL 3. No PIV applet is required.

> [!IMPORTANT]
> This procedure does **not** convert OpenPGP into PIV or install a PIV applet. It exposes a private key in the OpenPGP authentication slot through Scute's PKCS#11 interface and pairs it with an X.509 certificate. That was sufficient for `sbsign` on the tested system.
>
> The demonstration used a **disposable, self-signed test certificate** and did **not** modify UEFI Secure Boot databases. Do not enroll the test certificate or use an unbacked-up test key as a production signing authority.

## At a glance

**Hardware and software successfully tested on 27 October 2026:**

| Component | Configuration |
| --- | --- |
| Security key | Token2 Mini, USB `349e:0014` |
| Applet | OpenPGP card application, reported version `3.4` |
| Private key | On-device RSA-2048 in `OPENPGP.3` (authentication slot) |
| OS | Debian forky/sid, amd64 |
| GnuPG access | `gpg-agent` + `scdaemon` |
| PKCS#11 bridge | Scute via `p11-kit-proxy.so` |
| OpenSSL | 3.6.5, `pkcs11-provider` 1.3.0 |
| Signing | Debian `sbsign` with provider support |
| Result | Signed EFI binary; signature inspected and verified by `sbverify` |

The OpenPGP application version `3.4` **is not** Token2 firmware release R3.4 and does not imply PIV support.

```text
sbsign
  └─ OpenSSL 3 + pkcs11-provider
       └─ p11-kit-proxy.so
            └─ scute.so
                 └─ gpg-agent / scdaemon
                      └─ Token2 Mini / OpenPGP.3 RSA private key
```

All example commands use **USER (`$`)** unless a section explicitly says **ROOT (`#`)**. There is no `sudo` in this guide. Library paths are from Debian amd64; confirm them on other architectures.

## Prerequisites

Install the necessary packages as **ROOT (`#`)**:

```sh
apt install --no-install-recommends \
  gnupg scdaemon gpgsm scute opensc p11-kit p11-kit-modules \
  pkcs11-provider sbsigntool
```

`opensc` supplies `pkcs11-tool`. The `--no-install-recommends` option avoids unnecessarily enabling other smart-card services during this test.

Check the inserted Token2 as **USER (`$`)**:

```sh
lsusb -d 349e:0014
gpg --card-status
```

If GnuPG reports `No SmartCard daemon`, check that `scdaemon` is installed. On our machine, `pcscd` interfered with GnuPG's direct CCID access. We stopped PC/SC **temporarily**, as **ROOT (`#`)**:

```sh
systemctl stop pcscd.socket pcscd.service
```

Then as **USER (`$`)**:

```sh
gpgconf --kill scdaemon
gpg --card-status
```

Do not disable PC/SC indiscriminately if another smart card depends on it.

## 1. Generate a private key in the OpenPGP authentication slot

First inspect the PIN retry counters:

```sh
gpg --card-status | grep 'PIN retry counter'
```

Then open the card utility:

```sh
gpg-card
```

At its prompt:

```text
gpg/card> generate --algo=rsa2048 OPENPGP.3
gpg/card> quit
```

This creates an RSA private key **on the device**. The operation uses the **OpenPGP Admin PIN**, separate from the OpenPGP User PIN and the FIDO2 PIN. Set non-default PINs, and stop to inspect the retry counters if you see `Bad PIN` rather than guessing repeatedly.

The resulting private key is non-exportable through the card interface. If the device is lost, the on-card-generated test key is lost. Do not overwrite an existing key in `OPENPGP.3` without understanding the consequences.

Confirm that `gpg --card-status` now lists an authentication key.

## 2. Create a self-signed X.509 certificate for that key

Work in an isolated test directory:

```sh
mkdir -p "$HOME/token2-lab"
cd "$HOME/token2-lab"

gpgsm --learn
gpgsm --gen-key --output token2-test.pem
```

In the interactive prompts, select **existing key from card**, choose `OPENPGP.3`, choose signing usage, set a subject such as `CN=Token2 Secure Boot Test`, and request a **self-signed certificate**. Exact menu numbers can vary; in our test, they were `3` for an existing card key and `2` for signing.

Check the output's actual encoding and certificate fields:

```sh
head -n 1 token2-test.pem
openssl x509 -in token2-test.pem -noout -subject -issuer -dates
```

The first line should be `-----BEGIN CERTIFICATE-----` for PEM. In our experiment, GPGSM generated **PEM despite an initial `.der` filename**. An attempt to parse it with `openssl x509 -inform DER` failed; renaming the file (or simply reading it as PEM) resolved the problem. No new cryptographic key was needed.

Import the certificate into GPGSM's certificate store:

```sh
gpgsm --import token2-test.pem
gpgsm --list-secret-keys
```

The listing should show an RSA-2048 certificate and a `card s/n:` referring to the inserted Token2. This associates an X.509 certificate with the hardware-backed private key; it does **not** export that key.

## 3. Confirm Scute exports the X.509 identity

Use OpenSC's diagnostic utility, rather than relying on `p11tool` token enumeration:

```sh
SCUTE=/usr/lib/x86_64-linux-gnu/scute/scute.so

pkcs11-tool --module "$SCUTE" --list-slots
pkcs11-tool --module "$SCUTE" --list-objects
pkcs11-tool --module "$SCUTE" --list-mechanisms
```

We observed:

- A slot identified as `GnuPG Smart Card Daemon`.
- A **2048-bit RSA private-key object** and matching X.509 certificate, labeled `Scute`.
- `RSA-PKCS` (`CKM_RSA_PKCS`) as a hardware signing mechanism.
- Private-key metadata indicating **never extractable**.

For this particular combination, `p11tool --provider "$SCUTE" --list-tokens` gave no useful result, whereas `pkcs11-tool` successfully discovered the card and objects.

## 4. Put p11-kit between Scute and OpenSSL

Loading Scute **directly** through `pkcs11-provider` initially failed with:

```text
Internal locking failure
Module initialization failed
scute_agent_finalize: no GPG Agent connection established
```

The working path used **p11-kit as the module manager and proxy**.

Create the Scute module registration:

```sh
mkdir -p "$HOME/.config/pkcs11/modules"

cat > "$HOME/.config/pkcs11/modules/scute.module" <<'CONF'
module: /usr/lib/x86_64-linux-gnu/scute/scute.so
managed: yes
CONF
```

### Isolate Scute from other installed modules (tested workaround)

On the test machine the proxy also loaded `opensc-pkcs11` and `ykcs11` and returned `CKR_DEVICE_ERROR`. We isolated Scute with these **temporary per-user overrides**:

```sh
cat > "$HOME/.config/pkcs11/modules/opensc-pkcs11.module" <<'CONF'
module:
CONF

cat > "$HOME/.config/pkcs11/modules/ykcs11.module" <<'CONF'
module:
CONF
```

This is the **configuration used in the successful experiment**, but it produced nonfatal `Is a directory` warnings in `p11-kit -v list-modules`. These overrides affect the current user's p11-kit applications. They are deliberately **not** presented as a finished production configuration; a cleaner, scoped module-selection solution is still needed for `devoid`.

Do **not** add `enable-in: p11-kit-proxy` to Scute for this diagnostic workflow: it caused the module to be excluded when invoked from `pkcs11-tool`.

Now verify the proxy:

```sh
PROXY=/usr/lib/x86_64-linux-gnu/p11-kit-proxy.so

p11-kit -v list-modules
pkcs11-tool --module "$PROXY" --list-slots
pkcs11-tool --module "$PROXY" --list-objects
```

The proxy should enumerate the same Token2 RSA key and certificate as direct Scute access.

## 5. Configure an isolated OpenSSL 3 provider environment

**Do not edit `/etc/ssl/openssl.cnf` for this experiment.** A global PKCS#11 configuration can affect unrelated OpenSSL consumers, including Node.js and development tools.

In `~/token2-lab`, create a local configuration:

```sh
cat > token2-openssl.cnf <<'CONF'
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect
pkcs11 = pkcs11_sect

[default_sect]
activate = 1

[pkcs11_sect]
activate = 1
pkcs11-module-path = /usr/lib/x86_64-linux-gnu/p11-kit-proxy.so
CONF

export OPENSSL_CONF="$PWD/token2-openssl.cnf"
export PKCS11_PROVIDER_MODULE=/usr/lib/x86_64-linux-gnu/p11-kit-proxy.so
```

This configuration points **directly to the proxy**. During the original experiment, the file still pointed to Scute, but `PKCS11_PROVIDER_MODULE` overrode it with the proxy path; the provider debug trace verified the effective module. The version above makes the intended target explicit.

Check the providers:

```sh
openssl list -providers
```

Both `default` and `pkcs11` should be active.

Obtain your own card-specific key URI from `pkcs11-tool --module "$PROXY" --list-objects`, then set `KEY_URI`. For the tested card it was:

```sh
KEY_URI='pkcs11:token=D2760001240103040011133036860000;object=Scute;type=private'
```

**Do not reuse that card serial number on another device.** Check whether OpenSSL can retrieve the key *reference* (not the private key material):

```sh
openssl storeutl -keys -noout "$KEY_URI"
```

Successful output:

```text
0: Pkey
Total found: 1
```

When diagnosing provider failures, this was useful:

```sh
PKCS11_PROVIDER_DEBUG='file:/dev/stderr,level:2' \
  openssl storeutl -keys -noout "$KEY_URI"
```

The actual trace showed `C_Initialize` succeeding through `p11-kit-proxy.so`, a single `CKM_RSA_PKCS` mechanism, and successful private-key **object discovery**. It did not expose the private key bytes.

## 6. Sign a disposable EFI binary and verify it

The tested Debian `sbsign` build supports an **OpenSSL provider** named with the historical `--engine` option. This is version/distribution-specific; do not assume all `sbsign` builds have the same behavior.

Check the OpenPGP PIN counters before requesting a signature:

```sh
gpg --card-status | grep 'PIN retry counter'
```

Our card reported `3 0 3`, even though Scute's PKCS#11 token flags said `user PIN final try`. We used GnuPG's actual counter to determine the remaining attempts.

With the environment from step 5 still active, identify an EFI executable to sign **as a copy**, not as an installed boot file:

```sh
EFI=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
ls -l "$EFI"
```

If that path exists, sign it:

```sh
sbsign --engine pkcs11 \
  --key "$KEY_URI" \
  --cert token2-test.pem \
  --output token2-test.signed.efi \
  "$EFI"
```

Use the **OpenPGP User PIN** if prompted. Verify the resulting binary:

```sh
sbverify --list token2-test.signed.efi
sbverify --cert token2-test.pem token2-test.signed.efi \
  && echo 'EFI signature verified'
```

**Observed outcome:** `sbsign` produced a signed EFI binary, and `sbverify` recognized the embedded signature and the test certificate. The test certificate was not enrolled into Secure Boot firmware trust databases.

**Scope of the result:** We demonstrated `sbsign` interoperability. We did **not** test production `devoid.sh` integration, UKI-generation automation, DKMS/kernel module signing, firmware boot acceptance, or mandatory physical-touch enforcement for this OpenPGP slot.

## Troubleshooting

| Symptom | Explanation / tested response |
| --- | --- |
| `No SmartCard daemon` | Install `scdaemon`. |
| `OpenPGP card not available: No such device` | PC/SC conflicted with GnuPG direct CCID on this system. Stop `pcscd.socket`/`pcscd.service` temporarily and restart `scdaemon`. |
| `Bad PIN` on key generation | Verify the **OpenPGP Admin PIN** and retry counters, not the FIDO2 PIN. |
| OpenSSL cannot decode `.der` certificate | GPGSM's output may actually be PEM. Inspect the first line; omit `-inform DER` for PEM input. |
| GnuTLS `p11tool` finds no Scute tokens | Try OpenSC `pkcs11-tool` before concluding the device is absent. |
| `Internal locking failure` in `pkcs11-provider` | Loading Scute directly failed; using `p11-kit-proxy.so` worked. |
| p11-kit proxy returns `CKR_DEVICE_ERROR` | On this machine, temporarily excluding the other two registered modules allowed the proxy to work. The precise offending module was not proven. |
| Scute is absent during `pkcs11-tool` testing | Remove the `enable-in: p11-kit-proxy` restriction from its module configuration for this workflow. |
| OpenSSL says `No store loader found` | Ensure the `default` and `pkcs11` providers load and the provider's module is the proxy. |
| `sbsign --engine pkcs11` is rejected | Confirm that your `sbsign` version actually uses the provider interface; older builds may still expect the legacy ENGINE API. |

## Cleanup (user account)

The following reverses the **user-side configuration and test artifacts**, but **does not erase the on-token RSA key, reset PINs, uninstall packages, or change the system's PC/SC service state**.

As **USER (`$`)**, remove only the files created by this procedure:

```sh
rm -f \
  "$HOME/.config/pkcs11/modules/scute.module" \
  "$HOME/.config/pkcs11/modules/opensc-pkcs11.module" \
  "$HOME/.config/pkcs11/modules/ykcs11.module"

rmdir "$HOME/.config/pkcs11/modules" "$HOME/.config/pkcs11" 2>/dev/null || true

cd "$HOME/token2-lab"
rm -f token2-openssl.cnf token2-test.pem token2-test.signed.efi

unset OPENSSL_CONF PKCS11_PROVIDER_MODULE PKCS11_MODULE_PATH
unset PKCS11_PROVIDER_DEBUG SCUTE_DEBUG
unset KEY_URI SCUTE PROXY EFI
```

Optionally remove the **test certificate only** from the GPGSM certificate store. Identify its fingerprint first:

```sh
gpgsm --list-secret-keys
```

Then run `gpgsm --delete-keys` with **that certificate's** fingerprint; never use an unverified fingerprint copied from someone else's example. Avoid blindly deleting `~/.gnupg/private-keys-v1.d/` entries: they can contain hardware-key references used by other workflows.

## Before integrating this into `devoid.sh`

This is a working proof of concept, not yet a drop-in replacement for the installer's existing YubiKey/PIV signing path. Production integration still needs:

1. A **root-owned** GnuPG agent and certificate/key references (the user's GPGSM store and agent are not inherited by root).
2. A narrowly scoped p11-kit configuration without the experimental empty-module overrides.
3. Verified PIN and **touch-confirmation** behavior during every signing operation. A successful signature alone does not prove enforced physical presence.
4. A production signing certificate/key policy: recovery, key lifecycle, algorithms and UEFI enrollment.
5. Separate end-to-end tests for UKI creation and DKMS/kernel module signing.
6. An isolated OpenSSL provider environment, leaving global OpenSSL/Node.js behavior unchanged.

## References

- [Scute manual](https://gnupg.org/documentation/manuals/scute/)
- [GnuPG card utility](https://www.gnupg.org/documentation/manuals/gnupg26/gpg-card.1.html)
- [OpenSSL `pkcs11-provider`](https://github.com/openssl-projects/pkcs11-provider)
- [p11-kit module configuration](https://github.com/p11-glue/p11-kit/blob/master/doc/manual/pkcs11.conf.xml)
- [Debian discussion of the `sbsign` provider migration](https://lists.debian.org/debian-efi/2026/07/msg00032.html)

## Credits

**Experiment and hardware validation:** [devoid-of-void](https://github.com/devoid-of-void), maintainer of [devoid](https://github.com/devoid-of-void/devoid).  
**Collaborative research, debugging and documentation:** **ChatGPT (GPT-6, OpenAI)**.

This guide records a real, successful test on Debian rather than a claim that the Token2 implements PIV.