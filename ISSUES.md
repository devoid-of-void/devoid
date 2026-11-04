# Installation issues and findings (Token2 branch)

Observed on 2026-11-03 during a fresh Debian forky/sid installation with `devoid` on an MSI MEG Z790 ACE (AMI UEFI 2.90 / firmware 5.32). These are installation and platform integration findings, not necessarily defects in Token2 OpenPGP signing.

## 1. Critical: MSI reports Secure Boot enabled while executing unsigned EFI binaries

**Status:** Resolved on the test machine by selecting **Secure Boot Preset → Maximum Security** in UEFI setup. Installer-side warning/documentation still needed.

**Observed:**
- `bootctl status` reported `Secure Boot: enabled (user)`; `mokutil --sb-state` reported `SecureBoot enabled`.
- Efivarfs values were `SecureBoot=1`, `SetupMode=0`, `AuditMode=0`, `DeployedMode=0`, `VendorKeys=0`.
- PK and KEK held the custom `CN=devoid Secure Boot` certificate; `db` contained that certificate and **two intentional SHA-256 allowlist entries for the RTX 3090 and GTX 1060 GOP drivers**.
- An **unsigned test Debian installation booted**, despite the expected strict policy. Its `EFI/BOOT/BOOTX64.EFI`, `EFI/systemd/systemd-bootx64.efi`, and both UKIs showed `No signature table present` under `sbverify --list`.
- The newer firmware did **not** expose the older MSI `Image Execution Policy` controls.
- The operator found `Secure Boot Preset → Maximum Security` and confirmed that this was the missing enforcement setting.

**Security consequence:** Reading Secure Boot variables and checking enrolled keys does **not** suffice to prove that the firmware rejects unauthorized EFI images. An installer can finish successfully while firmware policy remains permissive.

**Proposed follow-up:**
1. Add an explicit warning for MSI boards with a `Secure Boot Preset` option: select **Maximum Security**, without resetting custom keys.
2. Explain that `SecureBoot=1`, `SetupMode=0`, and `AuditMode=0` alone are insufficient as an *empirical* verification of enforcement.
3. Provide an opt-in, controlled **negative boot test** using a known-unsigned EFI binary, with a signed recovery boot path prepared. Do not modify or erase enrolled keys as part of this test.
4. Consider documenting detected board/firmware details in installer diagnostic output. Do not assume the setting is present on every MSI BIOS.

## 2. GNOME/GDM Wayland fails when NVIDIA DRM KMS is disabled

**Status:** Resolved on the test machine by enabling `nvidia_drm` modesetting and framebuffer support; default configuration/documentation follow-up recommended.

**Environment:** Fresh Sid installation, first GDM start; NVIDIA proprietary driver `550.163.01` bound to both RTX 3090 and GTX 1060.

**Observed:**
- GNOME Shell: `Failed to open gpu '/dev/dri/card0': No suitable mode setting backend found` (also `card1`), followed by `Failed to setup: No GPUs found`.
- GDM: `maximum number of display failures reached. Giving up.`
- `nvidia-smi` successfully enumerated both GPUs; `nvidia`, `nvidia_modeset`, and `nvidia_drm` were loaded; `/dev/dri/card0`, `card1`, and render nodes existed.
- Kernel lockdown was `none [integrity] confidentiality`; no module signature rejection was evident in the displayed logs.
- Both `/sys/module/nvidia_drm/parameters/modeset` and `.../fbdev` returned `N`.

**Applied fix** (root):
```sh
cat >/etc/modprobe.d/nvidia-drm.conf <<'EOF'
options nvidia_drm modeset=1 fbdev=1
EOF
```
After reboot, the user reported a working fresh installation with GNOME.

**Proposed follow-up:**
1. When a proprietary NVIDIA driver and GNOME Wayland are selected, ensure `nvidia_drm.modeset=1` and, where supported/required, `fbdev=1` take effect.
2. If the driver is initialized in the initramfs, regenerate the initramfs/UKI and re-sign through the existing Token2 workflow; otherwise a modprobe drop-in followed by reboot may suffice.
3. Add a post-install diagnostic check for both parameters and GDM failures.
4. Do not assume this addresses the separate goal of using proprietary NVIDIA on RTX 3090 and Nouveau on GTX 1060. At the time of diagnosis the proprietary driver had bound to **both** GPUs.

## 3. Additional observations to triage

- `systemd-modules-load.service` failed during boot; the cause was not captured. Investigate separately if it persists.
- `bootctl` logged `loader.conf: Unknown line 'random-seed-mode', ignoring` under systemd-boot 262-1. Check whether the installer still generates this unsupported directive.
- Multiple ESP/UEFI boot entries were present. The unsigned test installation booted via the removable fallback `EFI/BOOT/BOOTX64.EFI`; do not conflate its ESP with the signed `devoid` installation's ESP.

## Validation checklist for a follow-up installation

- [ ] Verify PK/KEK/db and current Secure Boot variables.
- [ ] On applicable MSI firmware, set **Secure Boot Preset → Maximum Security**.
- [ ] Confirm a prepared, independently unsigned EFI test image is **rejected**, while the signed `devoid` UKI **boots**.
- [ ] Confirm NVIDIA driver loading and `nvidia_drm` `modeset=Y` / `fbdev=Y` when using GNOME Wayland.
- [ ] Confirm GDM starts and check `systemd-modules-load.service` diagnostics.
- [ ] Verify no obsolete `random-seed-mode` directive is written by the installer.
