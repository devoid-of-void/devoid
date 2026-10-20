#!/usr/bin/env bash
# Debian Forky, XFS/LUKS2, FIDO2, YubiKey PIV signing, and owner-only Secure Boot.
# Run from an amd64 Debian live system in UEFI Setup Mode. This erases a disk.
# The existing signing key and certificate in PIV slot 9c are never replaced.
set -Eeuo pipefail

readonly RELEASE=forky
readonly TARGET=/mnt/target
readonly MAPPER=devoid-root
readonly KEY_DIR=/etc/kernel/keys
readonly CERT_DER=$KEY_DIR/signing-certificate.der
readonly CERT_PEM=$KEY_DIR/signing-certificate.pem
readonly PIN_KEY=devoid:piv-pin
readonly EFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
readonly BOOT_LABEL='Debian GNU/Linux installed by devoid'

# Host-owned resources. Only resources acquired by this invocation are released.
work=
root_open=0
target_mounted=0
securityfs_mounted=0
pin_cached=0
phase=startup

die() { printf 'devoid: %s\n' "$*" >&2; exit 1; }
stage() { phase=$1; printf '\n== %s ==\n' "$phase"; }
packages() { apt-get install -y --no-install-recommends -o Dpkg::Progress-Fancy=1 "$@"; }

cleanup() {
    local status=$?
    trap - EXIT ERR INT TERM HUP
    set +e
    if (( pin_cached )); then
        keyctl unlink "$(keyctl search @s user "$PIN_KEY")" @s || status=1
    fi
    if (( target_mounted )); then
        sync
        umount -R "$TARGET" || { printf 'Could not unmount %s\n' "$TARGET" >&2; status=1; }
    fi
    if (( root_open )); then
        cryptsetup close "$MAPPER" || { printf 'Could not close %s\n' "$MAPPER" >&2; status=1; }
    fi
    if (( securityfs_mounted )); then
        umount /sys/kernel/security || status=1
    fi
    [[ -z $work ]] || rm -rf -- "$work"
    exit "$status"
}

install_traps() {
    # Report the stage and line, not the command: commands may contain secrets.
    trap 'printf "devoid: %s failed at line %s (status %s).\n" "$phase" "$LINENO" "$?" >&2' ERR
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
}

require_setup_mode() {
    local value
    value=$(od -An -tu1 -j4 -N1 "/sys/firmware/efi/efivars/SetupMode-$EFI_GLOBAL")
    [[ ${value//[[:space:]]/} == 1 ]] || die 'Enter UEFI Setup Mode before enrollment.'
}

prepare_host() {
    stage 'Prepare live system'
    [[ $EUID == 0 ]] || die 'Run as root.'
    [[ $(uname -m) == x86_64 ]] || die 'This installer targets amd64.'
    [[ -d /sys/firmware/efi/efivars ]] || die 'Boot the live system in UEFI mode.'
    require_setup_mode
    [[ -c /dev/tpmrm0 ]] || die 'A TPM 2.0 resource-manager device is required.'
    [[ ! -e /dev/mapper/$MAPPER ]] || die "Mapper $MAPPER is already in use."
    mountpoint -q "$TARGET" && die "$TARGET is already mounted."

    apt-get update
    packages dialog gdisk uuid-runtime parted dosfstools xfsprogs mmdebstrap \
        cryptsetup systemd-cryptsetup systemd-container efibootmgr efitools \
        tpm2-tools sbsigntool yq xxd libpam-u2f pamu2fcfg \
        yubico-piv-tool ykcs11 opensc pcscd pcsc-tools usbutils
    systemctl start pcscd.socket
    dialog --keep-tite --title 'YubiKey' --msgbox 'Insert your configured YubiKey.' 7 60
    yubico-piv-tool -a status

    work=$(mktemp -d /run/devoid.XXXXXX)
    install -d -m 0700 "$work/credentials"
    yubico-piv-tool -s9c -a read-certificate -o "$work/signing.pem"
}

select_disk() {
    stage 'Select installation disk'
    lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINTS
    disk=$(dialog --keep-tite --stdout --inputbox 'Whole disk to erase:' 8 72)
    disk=$(readlink -e -- "$disk")
    [[ -b $disk && $(lsblk -dnro TYPE "$disk") == disk ]] || die 'Select a whole disk.'
    # Reject mounted descendants, active swap, and active device-mapper/RAID users.
    local devices device mounts confirmation
    devices=$(lsblk -nrpo NAME "$disk")
    mounts=$(lsblk -nrpo MOUNTPOINTS "$disk")
    [[ -z ${mounts//[[:space:]]/} ]] || die 'The selected disk has mounted filesystems or swap.'
    while read -r device; do
        [[ -z $(ls -A "/sys/class/block/${device##*/}/holders") ]] \
            || die "$device has active block-device users."
    done <<< "$devices"
    confirmation=$(dialog --keep-tite --stdout --inputbox \
        "Erase ALL data on $disk? Type its full path to proceed:" 9 76)
    [[ $confirmation == "$disk" ]] || die 'Disk erasure cancelled.'
    hostname=$(dialog --keep-tite --stdout --inputbox 'Hostname:' 8 60 'devoid-forky')
    [[ $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
        || die 'Use a hostname of 1–63 letters, digits or interior hyphens.'
}

collect_driver_hashes() {
    stage 'Prepare UEFI driver allowlist'
    if ! mountpoint -q /sys/kernel/security; then
        mount -t securityfs securityfs /sys/kernel/security
        securityfs_mounted=1
    fi
    cp /sys/kernel/security/tpm0/binary_bios_measurements "$work/tpm-eventlog.bin"
    tpm2_eventlog "$work/tpm-eventlog.bin" > "$work/tpm-eventlog.yaml"
    yq -r '
        .events[]
        | select(.PCRIndex == 2)
        | select(.EventType | contains("SERVICES_DRIVER"))
        | .Digests[]
        | select(.AlgorithmId == "sha256")
        | .Digest
    ' "$work/tpm-eventlog.yaml" | sort -u > "$work/uefi-drivers.sha256"
    [[ -s $work/uefi-drivers.sha256 ]] || die 'No SHA-256 driver measurements found in PCR 2.'

    owner=$(uuidgen)
    local hash
    : > "$work/uefi-drivers.esl"
    while read -r hash; do
        [[ $hash =~ ^[[:xdigit:]]{64}$ && $hash != $(printf '%064d' 0) ]] \
            || die "Invalid driver measurement: $hash"
        printf '%s' "$hash" | xxd -r -p > "$work/driver.hash"
        sbsiglist --owner "$owner" --type sha256 \
            --output "$work/driver.esl" "$work/driver.hash"
        cat "$work/driver.esl" >> "$work/uefi-drivers.esl"
    done < "$work/uefi-drivers.sha256"
}

partition_disk() {
    stage 'Partition disk'
    esp_uuid=$(uuidgen)
    root_uuid=$(uuidgen)
    sgdisk --zap-all "$disk"
    sgdisk --new=1:2048:+2G --typecode=1:ef00 \
        --change-name=1:'EFI system partition' --partition-guid="1:$esp_uuid" \
        --new=2:0:0 --typecode=2:8300 \
        --change-name=2:'Root partition' --partition-guid="2:$root_uuid" "$disk"
    partprobe "$disk"
    udevadm settle
    esp=/dev/disk/by-partuuid/$esp_uuid
    root_partition=/dev/disk/by-partuuid/$root_uuid
    wipefs -a "$esp"
    mkfs.vfat -F32 -n EFI "$esp"
}

enroll_luks() {
    stage 'Create encrypted root and enroll FIDO2'
    local passphrase repeated pin
    passphrase=$(dialog --keep-tite --stdout --title 'LUKS2 recovery' --passwordbox 'Recovery passphrase:' 8 60)
    repeated=$(dialog --keep-tite --stdout --title 'LUKS2 recovery' --passwordbox 'Repeat passphrase:' 8 60)
    [[ -n $passphrase && $passphrase == "$repeated" ]] || die 'Passphrases are empty or do not match.'
    unset repeated
    printf '%s' "$passphrase" | cryptsetup luksFormat "$root_partition" --type luks2 --batch-mode --key-file=-
    printf '%s' "$passphrase" | cryptsetup open "$root_partition" "$MAPPER" --key-file=-
    root_open=1
    printf '%s' "$passphrase" | systemd-creds encrypt --name=cryptenroll.passphrase \
        - "$work/credentials/cryptenroll.passphrase"
    unset passphrase
    pin=$(dialog --keep-tite --stdout --title 'FIDO2' --passwordbox 'FIDO2 PIN:' 8 60)
    printf '%s' "$pin" | systemd-creds encrypt --name=cryptenroll.fido2-pin \
        - "$work/credentials/cryptenroll.fido2-pin"
    unset pin
    systemd-run --pty --wait --collect \
        --property="LoadCredentialEncrypted=cryptenroll.passphrase:$work/credentials/cryptenroll.passphrase" \
        --property="LoadCredentialEncrypted=cryptenroll.fido2-pin:$work/credentials/cryptenroll.fido2-pin" \
        /usr/bin/systemd-cryptenroll --fido2-device=auto \
        --fido2-with-client-pin=yes --fido2-with-user-presence=yes "$root_partition"
    # Preserve the original provisional TPM token. Reseal after booting with SB enabled.
    systemd-run --pty --wait --collect \
        --property="LoadCredentialEncrypted=cryptenroll.passphrase:$work/credentials/cryptenroll.passphrase" \
        /usr/bin/systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --wipe-slot=tpm2 "$root_partition"
    rm "$work/credentials/cryptenroll.passphrase" "$work/credentials/cryptenroll.fido2-pin"
    luks_uuid=$(cryptsetup luksUUID "$root_partition")
}

bootstrap_target() {
    stage 'Create XFS and bootstrap Debian'
    fs_uuid=$(uuidgen)
    mkfs.xfs -f -m "uuid=$fs_uuid" -L root "/dev/mapper/$MAPPER"
    mkdir -p "$TARGET"
    mount "/dev/mapper/$MAPPER" "$TARGET"
    target_mounted=1
    mkdir -p "$TARGET/boot/efi"
    mount "$esp" "$TARGET/boot/efi" -o umask=077
    unshare -m mmdebstrap --mode=root --variant=apt "$RELEASE" "$TARGET" \
        --components='main contrib non-free non-free-firmware' --skip=check/empty
    cat > "$TARGET/etc/fstab" <<EOF
/dev/mapper/luks-$luks_uuid / xfs defaults 0 1
PARTUUID=$esp_uuid /boot/efi vfat defaults,umask=077 0 2
/swapfile none swap sw 0 0
EOF
    install -d -m 0755 "$TARGET/etc/kernel"
    printf '%s\n' "quiet splash rw root=UUID=$fs_uuid rootfstype=xfs rd.luks.uuid=$luks_uuid rd.luks.options=$luks_uuid=fido2-device=auto,tpm2-device=auto" \
        > "$TARGET/etc/kernel/cmdline"
    printf '%s\n' "$hostname" > "$TARGET/etc/hostname"
    printf '127.0.1.1 %s\n' "$hostname" >> "$TARGET/etc/hosts"
    install -d -m 0700 "$TARGET$KEY_DIR" "$TARGET/etc/u2f_mappings"
    cp "$work"/tpm-eventlog.* "$work"/uefi-drivers.* "$TARGET$KEY_DIR/"
    printf '%s\n' "$owner" > "$TARGET$KEY_DIR/owner.guid"

    stage 'Enroll root login credential'
    # Let pamu2fcfg handle PIN entry; stdout contains only the mapping.
    pamu2fcfg --username=root --origin="pam://$hostname" --pin-verification \
        > "$TARGET/etc/u2f_mappings/u2f_keys"
    chmod 600 "$TARGET/etc/u2f_mappings/u2f_keys"
}

configure_target() {
    stage 'Configure installed system'
    # Only PC/SC is needed by target-side signing; firmware and TPM stay on the host.
    unshare -m systemd-nspawn --directory="$TARGET" --timezone=off --console=interactive --resolv-conf=copy-host \
        --bind-ro="$(readlink -f -- "${BASH_SOURCE[0]}"):/devoid-installer.sh" \
        --bind=/run/pcscd -- /bin/bash /devoid-installer.sh target "$luks_uuid"
}

configure_accounts() {
    stage 'Configure locale and root account'
    apt-get update
    packages dialog locales tzdata keyboard-configuration adduser
    packages git curl ca-certificates zsh sudo openssh-client openssh-server sshfs \
        libpam-u2f pamu2fcfg openssl
    local password
    password=$(openssl rand -base64 18)
    printf 'root:%s\n' "$password" | chpasswd
    dialog --keep-tite --title 'Root recovery password' --msgbox "$password\n\nRecord this password." 10 70
    unset password
    local service
    for service in su login; do
        sed -i '1i auth sufficient pam_u2f.so authfile=/etc/u2f_mappings/u2f_keys cue pinverification=1 userpresence=1' "/etc/pam.d/$service"
    done
    # Retain the original shell and theme; separate download from execution.
    curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh \
        -o /root/oh-my-zsh-install.sh
    sh /root/oh-my-zsh-install.sh --unattended
    rm /root/oh-my-zsh-install.sh
    sed -i 's/ZSH_THEME=".*"/ZSH_THEME="risto"/' /root/.zshrc
    chsh -s /usr/bin/zsh root
}

prepare_signing() {
    stage 'Configure YubiKey signing'
    packages keyutils gnutls-bin mokutil sbsigntool tpm2-tools efitools uuid-runtime \
        yubico-piv-tool p11-kit p11-kit-modules opensc opensc-pkcs11 ykcs11 \
        pcscd pcsc-tools libengine-pkcs11-openssl pkcs11-provider
    local module provider pin objects
    module=$(dpkg -L ykcs11 | grep '/libykcs11.so$')
    provider=$(dpkg -L pkcs11-provider | grep '/ossl-modules/pkcs11.so$')
    install -d -m 0755 /usr/share/p11-kit/modules /etc/kernel/scripts
    cat > /usr/share/p11-kit/modules/ykcs11.module <<EOF
module: $module
label: YubiKey PIV
EOF
    pin=$(dialog --keep-tite --stdout --title 'Signing' --passwordbox 'PIV PIN:' 8 60)
    printf '%s' "$pin" | keyctl padd user "$PIN_KEY" @s > /dev/null
    pin_cached=1
    export PKCSPIN=$pin
    unset pin
    pkcs11-tool --module "$module" --read-object --type cert --id 02 --output-file "$CERT_DER"
    objects=$(pkcs11-tool --module "$module" --list-objects --id 02 --type privkey --login --pin env:PKCSPIN)
    signing_uri=$(printf '%s\n' "$objects" | grep -o 'pkcs11:.*')
    [[ $signing_uri == pkcs11:* && $signing_uri != *$'\n'* ]] || die 'Expected one private-key URI for PIV slot 9c.'
    openssl x509 -inform DER -in "$CERT_DER" -out "$CERT_PEM"

    # This configuration is used only by signing processes, not every OpenSSL user.
    cat > "$KEY_DIR/openssl-signing.cnf" <<EOF
openssl_conf = signing_init
[signing_init]
providers = signing_providers
engines = signing_engines
[signing_providers]
default = default_provider
pkcs11 = token_provider
[default_provider]
activate = 1
[token_provider]
module = $provider
pkcs11-module-path = $module
pkcs11-module-cache-pins = cache
pkcs11-module-login-behavior = auto
pkcs11-module-token-pin = \$ENV::PKCSPIN
activate = 1
[signing_engines]
pkcs11 = token_engine
[token_engine]
engine_id = pkcs11
MODULE_PATH = $module
PIN = \$ENV::PKCSPIN
init = 0
EOF
    export OPENSSL_CONF=$KEY_DIR/openssl-signing.cnf
    write_signing_helpers
    local guid
    guid=$(cat "$KEY_DIR/owner.guid")
    cert-to-efi-sig-list -g "$guid" "$CERT_PEM" "$KEY_DIR/owner.esl"
    # -e names the libp11 ENGINE; provider-based UKI signing is configured separately.
    sign-efi-sig-list -e pkcs11 -k "$signing_uri" -c "$CERT_PEM" \
        PK "$KEY_DIR/owner.esl" "$KEY_DIR/PK.auth"
    install -d -m 0755 /boot/efi/EFI/secureboot
    cp "$CERT_DER" /boot/efi/EFI/secureboot/mok-cert.der
}

write_signing_helpers() {
    cat > /etc/kernel/scripts/piv-pin <<'SCRIPT'
#!/bin/bash
set -euo pipefail
if ! id=$(keyctl search @s user devoid:piv-pin 2>/dev/null); then
    pin=$(dialog --keep-tite --stdout --title 'Signing' --passwordbox 'PIV PIN:' 8 60)
    id=$(printf '%s' "$pin" | keyctl padd user devoid:piv-pin @s)
    unset pin
fi
keyctl print "$id"
SCRIPT
    cat > /etc/kernel/scripts/signing-environment <<'SCRIPT'
# Sourced by the UKI and DKMS hooks. Keep assignment separate from export so failure propagates.
PKCSPIN=$(/etc/kernel/scripts/piv-pin)
export PKCSPIN
export OPENSSL_CONF=/etc/kernel/keys/openssl-signing.cnf
SCRIPT
    install -d -m 0755 /etc/dkms/framework.conf.d
    cat > /etc/dkms/sign-helper <<'SCRIPT'
#!/bin/bash
set -euo pipefail
source /etc/kernel/scripts/signing-environment
# DKMS sign_file receives hash algorithm, key, certificate, and module path.
# Read the target kernel from the module, not the live installer's running kernel.
version=$(modinfo -F vermagic "$4")
version=${version%% *}
exec "/lib/modules/$version/build/scripts/sign-file" "$@"
SCRIPT
    cat > /etc/dkms/framework.conf.d/signing.conf <<EOF
mok_signing_key="$signing_uri"
mok_certificate="$CERT_DER"
sign_file="/etc/dkms/sign-helper"
EOF
    chmod 755 /etc/kernel/scripts/piv-pin /etc/dkms/sign-helper
}

configure_kernel() {
    stage 'Configure UKI generation'
    install -d -m 0755 /etc/dracut.conf.d /etc/sysusers.d /etc/kernel/postinst.d
    cat > /etc/kernel/install.conf <<'EOF'
layout=uki
initrd_generator=dracut
uki_generator=ukify
EOF
    cat > /etc/dracut.conf.d/devoid.conf <<'EOF'
add_dracutmodules+=" bash crypt plymouth drm tpm2-tss systemd-cryptsetup "
EOF
    # Preserve the original workaround for Debian #1056665 / #1100919.
    cat > /etc/sysusers.d/tpm2-tss.conf <<'EOF'
u tss - "TPM2 Software Stack user" /var/lib/tpm
g tss -
EOF
    cat > /etc/kernel/uki.conf <<EOF
[UKI]
SecureBootSigningTool=systemd-sbsign
SigningProvider=pkcs11
SignKernel=false
SecureBootPrivateKey=$signing_uri
SecureBootCertificate=$CERT_PEM
Cmdline=@/etc/kernel/cmdline
EOF
    cat > /etc/kernel/postinst.d/90-kernel-install <<'SCRIPT'
#!/bin/bash
set -euo pipefail
source /etc/kernel/scripts/signing-environment
exec kernel-install add "$1" "/boot/vmlinuz-$1"
SCRIPT
    cat > /etc/kernel/postinst.d/99-hints-update <<'SCRIPT'
#!/bin/bash
set -euo pipefail
cd /boot/efi/EFI/Linux
shopt -s nullglob
images=(*.efi)
(( ${#images[@]} )) || { echo 'No UKIs were generated.' >&2; exit 1; }
printf '%s\n' "${images[@]}" | sort -V -r |
    while read -r image; do
        printf '%s,Debian %s,,Installed by devoid\n' "$image" "${image%.efi}"
    done | iconv -f UTF-8 -t UTF-16LE > BOOTX64.CSV
SCRIPT
    chmod 755 /etc/kernel/postinst.d/{90-kernel-install,99-hints-update}
    dpkg-divert --local --rename --add /etc/kernel/postinst.d/dracut

    packages plymouth plymouth-themes systemd-ukify systemd-repart \
        systemd-cryptsetup dracut cryptsetup shim-unsigned \
        firmware-linux-free firmware-linux-nonfree firmware-atheros
    plymouth-set-default-theme solar
    DEBIAN_FRONTEND=noninteractive packages linux-image-amd64

    stage 'Sign fallback bootloader and verify boot images'
    local fallback image
    fallback=$(dpkg -L shim-unsigned | grep '/fbx64.efi$')
    install -d -m 0755 /boot/efi/EFI/BOOT
    /usr/lib/systemd/systemd-sbsign sign --private-key "$signing_uri" \
        --certificate "$CERT_PEM" --private-key-source provider:pkcs11 \
        "$fallback" --output /boot/efi/EFI/BOOT/BOOTX64.EFI
    sbverify --cert "$CERT_PEM" /boot/efi/EFI/BOOT/BOOTX64.EFI
    for image in /boot/efi/EFI/Linux/*.efi; do
        sbverify --cert "$CERT_PEM" "$image"
    done
    stage 'Install DKMS and its signing test'
    packages dkms linux-headers-amd64 dkms-test-dkms
}

finish_target() {
    stage 'Install networking and maintenance tools'
    packages network-manager usbutils nano vim iputils-ping wpasupplicant \
        systemd-resolved tasksel systemd-homed libfido2-1 fido2-tools
    systemctl enable NetworkManager.service systemd-resolved.service systemd-homed.service
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    # No automatic package updates: signing requires the owner and their YubiKey.
    systemctl mask apt-daily.timer apt-daily-upgrade.timer

    stage 'Create swap and post-install helpers'
    fallocate -l 8G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    cat > /root/tpm-enroll.sh <<EOF
#!/bin/bash
set -euo pipefail
value=\$(od -An -tu1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-$EFI_GLOBAL)
[[ \${value//[[:space:]]/} == 1 ]] || { echo 'Enable Secure Boot and reboot first.' >&2; exit 1; }
exec systemd-cryptenroll /dev/disk/by-uuid/$target_luks_uuid \\
    --tpm2-device=auto --tpm2-pcrs=7 --wipe-slot=tpm2 --unlock-fido2-device=auto
EOF
    cat > /root/create_homed_user.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 USERNAME" >&2; exit 2; }
systemctl enable --now systemd-homed
homectl create "$1" --storage=luks --fido2-device=auto --fs-type=ext4 \
    --disk-size=20G --fido2-with-client-pin=yes --fido2-with-user-presence=yes --recovery-key=yes
homectl activate "$1"
SCRIPT
    chmod 700 /root/tpm-enroll.sh /root/create_homed_user.sh
    keyctl unlink "$(keyctl search @s user "$PIN_KEY")" @s
    pin_cached=0
    unset PKCSPIN OPENSSL_CONF
}

install_boot_entry() {
    stage 'Install firmware boot entry'
    local entries entry efi_entry
    # Preserve the original dedicated-machine policy, including the debugging entry.
    entries=$(efibootmgr)
    while read -r entry; do
        efi_entry=${entry:4:4}
        efibootmgr --delete-bootnum --bootnum "$efi_entry"
    done < <(printf '%s\n' "$entries" | awk '/^Boot[[:xdigit:]]{4}/ && tolower($0) !~ /debugging/')
    efibootmgr --create --disk "$disk" --part 1 --label "$BOOT_LABEL" --loader '\EFI\BOOT\BOOTX64.EFI'
    entries=$(efibootmgr)
    entry=$(printf '%s\n' "$entries" | awk -v label="$BOOT_LABEL" 'index($0,label) {print substr($1,5,4)}')
    [[ $entry =~ ^[[:xdigit:]]{4}$ ]] || die 'Could not identify the new boot entry.'
    efibootmgr --bootorder "$entry" --bootnext "$entry"
}

enroll_secure_boot() {
    stage 'Enroll Secure Boot keys; PK last'
    require_setup_mode
    local keys=$TARGET$KEY_DIR
    efi-updatevar -e -f "$keys/owner.esl" db
    efi-updatevar -a -e -f "$keys/uefi-drivers.esl" db
    efi-updatevar -e -f "$keys/owner.esl" KEK
    efi-updatevar -f "$keys/PK.auth" PK
}

host_main() {
    install_traps
    prepare_host
    select_disk
    collect_driver_hashes
    partition_disk
    enroll_luks
    bootstrap_target
    configure_target

    stage 'Copy existing network profiles'
    local profiles=()
    shopt -s nullglob
    profiles=(/etc/NetworkManager/system-connections/*)
    if (( ${#profiles[@]} )); then
        install -d -m 0700 "$TARGET/etc/NetworkManager/system-connections"
        cp -a "${profiles[@]}" "$TARGET/etc/NetworkManager/system-connections/"
    fi
    install_boot_entry
    # Complete disk writes before committing the platform key.
    sync
    enroll_secure_boot
    stage 'Installation complete'
    printf '%s\n' 'Enable Secure Boot in firmware and reboot.' \
        'Unlock with FIDO2 or the recovery passphrase, then run /root/tpm-enroll.sh.' \
        'Create users with /root/create_homed_user.sh USERNAME; select a desktop with tasksel.'
}

target_main() {
    target_luks_uuid=$1
    install_traps
    export DEBIAN_FRONTEND=dialog
    configure_accounts
    prepare_signing
    configure_kernel
    finish_target
}

main() {
    case ${1:-install} in
        install) [[ $# -le 1 ]] || die 'Usage: devoid-alternative.sh [install]'; host_main ;;
        target) [[ $# == 2 ]] || die 'Internal target invocation requires the LUKS UUID.'; target_main "$2" ;;
        -h|--help) printf '%s\n' 'Usage: sudo ./devoid-alternative.sh' 'Interactive amd64 Debian installer. ERASES the selected disk. Requires UEFI Setup Mode.' ;;
        *) die "Unknown command: $1" ;;
    esac
}

# Sourcing exposes functions for non-destructive tests without starting installation.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
