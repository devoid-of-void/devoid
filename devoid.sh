#!/bin/bash
# devoid installs an opinionated Debian system with an encrypted XFS root,
# YubiKey-assisted unlocking and login, and signed unified kernel images (UKIs).
#
# Run from a Debian live environment booted in UEFI mode, with network access,
# a TPM 2.0 and a configured FIDO2/PIV YubiKey. Secure Boot key enrollment
# requires firmware Setup Mode and an existing signing key and certificate
# in the YubiKey's PIV slot 9c.
#
# Review the defaults below, then run from the directory containing this file:
#   sudo bash ./devoid.sh
#
# The selected installation disk will be erased. The script prepares it on
# the live host, then configures Debian inside a systemd-nspawn container.
# After booting the installed system with Secure Boot enabled, run
# /root/tpm-enroll.sh to enroll the TPM against the installed boot state.
# /root/create_homed_user.sh USER creates a user with a FIDO2-protected home.

set -euo pipefail
# set -x

#region User-selectable defaults
# readonly DEFAULT_DISK="/dev/disk/by-id/virtio-target"
readonly DEFAULT_DISK="/dev/disk/by-id/ata-KINGSTON_RBU-SNS8152S3256GG2_50026B7369011B0A"
readonly DEFAULT_DEBIAN_RELEASE="forky"
readonly DEFAULT_HOSTNAME="devoid-forky"
readonly DEFAULT_ESP_SIZE="10G"
readonly DEFAULT_SWAP_SIZE="8G"
readonly DEFAULT_HOMED_DISK_SIZE="100G"
readonly DEFAULT_TPM_PCRS="7"
readonly DEFAULT_ZSH_THEME="risto"
readonly DEFAULT_PLYMOUTH_THEME="solar"
#endregion

#region Internal constants
readonly TARGET="/mnt/target"
readonly CREDENTIALS_DIR="/run/credentials"
readonly TPM_EVENT_LOG="/sys/kernel/security/tpm0/binary_bios_measurements"

readonly LUKS_MAPPING_NAME="cryptoroot"
readonly LUKS_ROOT_DEVICE="/dev/mapper/${LUKS_MAPPING_NAME}"

readonly YUBIKEY_USB_ID="1050:0407"
# PKCS#11 object ID 02 identifies the signing key/certificate in PIV slot 9c.
readonly SIGNING_OBJECT_ID="02"
readonly PIV_PIN_KEY_NAME="devoid:piv-pin"

readonly KEYS_DIR="/etc/kernel/keys"
readonly SIGNING_KEY_BASE="${KEYS_DIR}/signing-certificate"
readonly SIGNING_CERTIFICATE_DER="${SIGNING_KEY_BASE}.der"
readonly SIGNING_CERTIFICATE_PEM="${SIGNING_KEY_BASE}.pem"
readonly SIGNING_KEY_ESL="${SIGNING_KEY_BASE}.esl"
readonly SIGNING_KEY_GUID="${SIGNING_KEY_BASE}.guid"
# Authenticated update for PK; it is not a generic update for db or KEK.
readonly PK_AUTH="${SIGNING_KEY_BASE}.auth"
readonly SERVICE_DRIVERS_BASE="${KEYS_DIR}/service-drivers"
readonly SERVICE_DRIVERS_HASHES="${SERVICE_DRIVERS_BASE}.sha256"
readonly SERVICE_DRIVERS_ESL="${SERVICE_DRIVERS_BASE}.esl"
#endregion

#region Host installation
host_side_code()
{
	#region Prepare the live environment
	apt update

	apt install -yqq --no-install-recommends --autoremove --purge -o Dpkg::Progress-Fancy=1 \
		dialog gdisk uuid-runtime parted dosfstools xfsprogs mmdebstrap cryptsetup \
		systemd-cryptsetup systemd-container efibootmgr \
		yubico-piv-tool ykcs11 \
		opensc opensc-pkcs11 p11-kit p11-kit-modules pcscd pcsc-tools \
		tpm2-tools efitools yq \
		libpam-u2f pamu2fcfg expect \
		gpg
		# for debugging purposes
		# apt install sshfs fuse openssh-server
		systemctl enable pcscd
		systemctl start pcscd
		dialog --keep-tite  --title "Restarting pcscd" --msgbox "\nPlease replug your YubiKey" 7 60
	#endregion

	#region Select the disk and check hardware
	l_disk=$(dialog --keep-tite  --stdout --inputbox "Enter installation disk:" 8 50 "${DEFAULT_DISK}")
	echo "Selected disk: $l_disk"
	error_message=""
	no_messages=0
	if [ ! -e "$l_disk" ]; then
		error_message+="\nInstallation disk not found.\n" >&2
		(( no_messages += 1 ))
	fi

	if ! lsusb | grep -q "$YUBIKEY_USB_ID"; then
		error_message+="\nYubikey not found.\n" >&2
		(( no_messages += 1 ))
	fi

	if [ ! -c "/dev/tpmrm0" ]; then
		error_message+="\nTPM 2.0 capability not detected.\n" >&2
		(( no_messages += 1 ))
	fi

	if [ -n "$error_message" ]; then
		dialog --keep-tite --title "Prerequisite Check Failed" --msgbox "$error_message" $((no_messages * 2 + 5)) 60
		# reset
		exit 1
	fi
	#endregion

	#region Partition the installation disk
	sgdisk --zap-all "${l_disk}"
	l_efi_system_partition_uuid=$(uuidgen)
	sgdisk --new=1:2048:+"$DEFAULT_ESP_SIZE"  \
			--typecode=1:ef00 \
			--change-name=1:"EFI system partition" \
			--partition-guid=1:"${l_efi_system_partition_uuid}" \
			"${l_disk}"

	l_root_partition_uuid=$(uuidgen)
	sgdisk --new=2:0:0 \
			--typecode=2:8300 \
			--change-name=2:"Root partition" \
			--partition-guid=2:"${l_root_partition_uuid}" \
			"${l_disk}"

	partprobe "${l_disk}"
	udevadm trigger --subsystem-match=block
	udevadm settle
	#endregion

	#region Format the EFI system partition
	l_efi_system_partition="/dev/disk/by-partuuid/${l_efi_system_partition_uuid}"
	wipefs -a "${l_efi_system_partition}"
	mkfs.vfat -F32 -n EFI "${l_efi_system_partition}"

	l_physical_root_partition="/dev/disk/by-partuuid/${l_root_partition_uuid}"

	udevadm trigger --subsystem-match=block
	udevadm settle
	#endregion

	#region Encrypt root and enroll FIDO2 and TPM unlocking

	# mkdir -p ignores -m for intermediate directories; set mode explicitly on the final
	install -d -m 0700 "$CREDENTIALS_DIR"

	luks2_pass=$(dialog --keep-tite --insecure --title "LUKS2 recovery" --passwordbox "\nEnter LUKS2 passphrase:" 9 40 2>&1 </dev/tty >/dev/tty)
	echo -n "$luks2_pass" | cryptsetup luksFormat "$l_physical_root_partition" --type luks2 --batch-mode --key-file=-

	echo -n "$luks2_pass" | cryptsetup open "$l_physical_root_partition" "$LUKS_MAPPING_NAME" --key-file=-

	echo -n "$luks2_pass" | systemd-creds encrypt --name=cryptenroll.passphrase - $CREDENTIALS_DIR/cryptenroll.passphrase
	unset luks2_pass

	fido2_pin=$(dialog --keep-tite --insecure --title "FIDO2 to LUKS2 enrollment" --passwordbox "\nEnter FIDO2 PIN:" 9 40 2>&1 </dev/tty >/dev/tty)
	echo -n "$fido2_pin" | systemd-creds encrypt --name=cryptenroll.fido2-pin - $CREDENTIALS_DIR/cryptenroll.fido2-pin

	systemd-run --pty --wait --collect 	\
	 			--property="LoadCredentialEncrypted=cryptenroll.fido2-pin:$CREDENTIALS_DIR/cryptenroll.fido2-pin" \
				--property="LoadCredentialEncrypted=cryptenroll.passphrase:$CREDENTIALS_DIR/cryptenroll.passphrase" \
		/usr/bin/systemd-cryptenroll --fido2-device=auto "$l_physical_root_partition"

	#if no tpm2 token is enrolled, systemd will fail to boot without asking for password, so here's one that will fallback to passphrase
	systemd-run --pty --wait --collect 	\
	 			--property="LoadCredentialEncrypted=cryptenroll.passphrase:$CREDENTIALS_DIR/cryptenroll.passphrase" \
		/usr/bin/systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs="$DEFAULT_TPM_PCRS" --wipe-slot=tpm2 "$l_physical_root_partition"

	shred -u "$CREDENTIALS_DIR/cryptenroll.fido2-pin"
	shred -u "$CREDENTIALS_DIR/cryptenroll.passphrase"


	l_luks_uuid=$(cryptsetup luksUUID "${l_physical_root_partition}")
	l_root_partition=${LUKS_ROOT_DEVICE}

	udevadm trigger --subsystem-match=block
	udevadm settle
	#endregion

	#region Format root and mount the target filesystems
	l_rootfs_uuid=$(uuidgen)
	wipefs -a "${l_root_partition}"
	mkfs.xfs -m uuid="${l_rootfs_uuid}" -L root "${l_root_partition}"

	# Temporary mountpoint
	mkdir -p "${TARGET}"
	mount "${l_root_partition}" "${TARGET}"

	# Persistent directories
	install -d -m 0755 "${TARGET}/home"
	install -d -m 0755 "${TARGET}/etc"

	# ESP mountpoint
	mkdir -p "${TARGET}/boot/efi"
	mount "${l_efi_system_partition}" "${TARGET}/boot/efi" -o umask=077
	#endregion

	#region Write filesystem mounts
	# GPT root partition (PARTUUID=<root-partuuid>)
	#     └─ LUKS2 container (UUID=<luks-uuid>)
	#         └─ /dev/mapper/cryptoroot
	#             └─ XFS filesystem (UUID=<rootfs-uuid>)

	echo "/dev/mapper/luks-${l_luks_uuid} / xfs defaults 0 1" > "${TARGET}"/etc/fstab
	echo "PARTUUID=${l_efi_system_partition_uuid} /boot/efi vfat defaults,umask=077 0 2" >> "${TARGET}"/etc/fstab
	echo "/swapfile none swap sw 0 0" >> "${TARGET}"/etc/fstab
	#endregion

	#region Bootstrap Debian
	unshare -m mmdebstrap --mode=root --variant=apt "${DEFAULT_DEBIAN_RELEASE}" "${TARGET}" \
		--components="main contrib non-free non-free-firmware"  \
		--skip=check/empty 
	#endregion
	
	#region Write the kernel command line
	install -d -m 0755 "${TARGET}"/etc/kernel
	# for debug shell add    "rd.debug rd.shell rd.break=pre-mount" 
	l_kernel_command_line="quiet splash rw root=UUID=${l_rootfs_uuid} rootfstype=xfs rd.luks.uuid=${l_luks_uuid} rootflags=rw "

	l_kernel_command_line+=" rd.luks.options=${l_luks_uuid}=pkcs11-uri=auto,tpm2-device=auto "

	echo "$l_kernel_command_line" > "${TARGET}"/etc/kernel/cmdline 
	#endregion

	#region Set the hostname
	l_hostname=$(dialog --keep-tite  --stdout --inputbox "Enter hostname:" 8 50 "$DEFAULT_HOSTNAME")
	echo "127.0.1.1 $l_hostname" >> "${TARGET}"/etc/hosts
	echo "$l_hostname" > "${TARGET}"/etc/hostname
	#endregion


	#region Enroll root's FIDO2 login credential
	echo "Please touch the YubiKey to enable passwordless root login..."
	expect <<- EOF > $CREDENTIALS_DIR/u2f_keys
		spawn pamu2fcfg --username=root --origin=pam://$l_hostname --pin-verification
		expect {
			"Enter PIN" { send "$fido2_pin\r" }
		}
		expect eof
	EOF

	unset fido2_pin
	install -d -m 0700 "${TARGET}/etc/u2f_mappings"
	grep "root" $CREDENTIALS_DIR/u2f_keys > "${TARGET}/etc/u2f_mappings/u2f_keys"
	shred -u $CREDENTIALS_DIR/u2f_keys
	#endregion

	#region Extract service-driver hashes from the host TPM log
	install -d -m 0700 "${TARGET}${KEYS_DIR}"
	# Include boot and runtime service drivers, but no EFI applications.
	tpm2_eventlog "$TPM_EVENT_LOG" | yq -er '
		[.events[] | select(.EventType | contains("SERVICES_DRIVER"))
		 | .Digests[] | select(.AlgorithmId == "sha256") | .Digest]
		| unique[]
	' > "${TARGET}${SERVICE_DRIVERS_HASHES}"
	#endregion

	#region Configure Debian inside systemd-nspawn
	
	# echo systemd-nspawn  --bind=devoid.sh:/devoid.sh \
	# 				--directory="${TARGET}" \
	# 				--bind="${l_physical_root_partition}" \
	# 				--bind="$(realpath "${l_physical_root_partition}")" \
    # 				--timezone=off \
	# 				--console=interactive \
	# 				--bind-ro=/run/udev \
	# 				--bind=/dev/bus/usb  \
	# 				--bind=/dev/bus/usb --bind=/dev/hidraw0 --bind=/dev/hidraw1 \
	# 				--bind=/dev/tpm0   \
	# 				--bind=/dev/tpmrm0 \
	# 				--bind=/run/pcscd/pcscd.comm \
	# 				--capability=CAP_SYS_ADMIN \
	# 				--bind=/sys/firmware/efi/efivars \
	# 				--property='"DeviceAllow=/dev/bus/usb rwm"' -- > run_cont.sh

	unshare -m systemd-nspawn  --bind=devoid.sh:/devoid.sh \
					--directory="${TARGET}" \
					--bind="${l_physical_root_partition}" \
					--bind="$(realpath "${l_physical_root_partition}")" \
                    --timezone=off \
					--console=interactive \
					--bind-ro=/run/udev \
					--bind=/dev/bus/usb \
					--bind=/dev/bus/usb --bind=/dev/hidraw0 --bind=/dev/hidraw1 \
					--bind=/dev/tpm0   \
					--bind=/dev/tpmrm0 \
					--bind=/run/pcscd/pcscd.comm \
					--capability=CAP_SYS_ADMIN \
					--bind=/sys/firmware/efi/efivars \
					-- /devoid.sh target "$l_physical_root_partition" 
					# --as-pid2 \
	#endregion

	#region Replace firmware boot entries (preserve debugging)
	# efibootmgr | grep -v -i "debugging" | awk '/^Boot[0-9]/{print substr($1,5,4)}' | xargs -n1 efibootmgr -B -b
	# l_deb=$(efibootmgr | grep -i "debian" | awk '/^Boot[0-9]/{print substr($1,5,4)}' )
	efibootmgr | grep -v -i "debugging" | awk '/^Boot[0-9]/{print substr($1,5,4)}' | xargs -n1 efibootmgr -B -b
	efibootmgr --create \
		--disk $l_disk \
		--part 1 \
		--label "Debian GNU/Linux installed by devoid" \
		--loader "EFI/BOOT/BOOTX64.EFI" \
		--bootnum 0000 \
		--bootorder 0000 \
		--bootnext 0000
	#endregion

	#region Copy NetworkManager connection profiles
	cp /etc/NetworkManager/system-connections/* "${TARGET}/etc/NetworkManager/system-connections/" || true
	#endregion

}

#endregion

#region Target configuration
target_side_code()
{
	p_physical_root_partition=$1

	#region Configure locale, timezone and keyboard
	apt update 
	apt-get install -y dialog -o Dpkg::Progress-Fancy=1 

	export DEBIAN_FRONTEND=dialog

	apt-get install -y locales tzdata keyboard-configuration adduser -o Dpkg::Progress-Fancy=1 
	#endregion

	#region Configure root authentication and shell
	apt-get install -y git -o Dpkg::Progress-Fancy=1  curl zsh sudo sudo ssh sshfs bash dialog libpam-u2f pamu2fcfg 

	root_pass=$(head -c 500 /dev/urandom | tr -dc 'A-Za-z0-9!@#$%' | head -c 12)

	echo "root:${root_pass}" | chpasswd

	dialog --title "Root passphrase" --msgbox "\n$root_pass\n\nThis is your root password. Keep it somewhere safe." 10 60

	unset root_pass

	sed -i '1i auth	 sufficient	 pam_u2f.so authfile=/etc/u2f_mappings/u2f_keys cue pinverification=1 userpresence=1' /etc/pam.d/su
	sed -i '1i auth	 sufficient	 pam_u2f.so authfile=/etc/u2f_mappings/u2f_keys cue pinverification=1 userpresence=1' /etc/pam.d/login

	sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
	sed -i "s/ZSH_THEME=\".*\"/ZSH_THEME=\"$DEFAULT_ZSH_THEME\"/" ~/.zshrc
	chsh -s "$(which zsh)"
	#endregion
	
	#region Install Secure Boot and module signing tools
	apt-get install -y keyutils gnutls-bin openssl mokutil sbsigntool xxd tpm2-tools tpm2-tss libgcrypt20 -o Dpkg::Progress-Fancy=1 
	#endregion

	#region Cache the PIV PIN for signing
	piv_pin=$(dialog --keep-tite --insecure --title "DKMS signing" --passwordbox "\nEnter PIV PIN:" 9 40 2>&1 </dev/tty >/dev/tty)
	keyctl add user "$PIV_PIN_KEY_NAME" "$piv_pin" @s
	export PKCSPIN=$piv_pin
	#endregion

	#region Configure YubiKey PKCS#11 access
	apt install --no-install-recommends -y -o Dpkg::Progress-Fancy=1  \
		yubico-piv-tool p11-kit p11-kit-modules opensc ykcs11 \
		opensc-pkcs11 pcscd pcsc-tools libengine-pkcs11-openssl pkcs11-provider 

	# get the path to the YubiKey PKCS#11 module, which is needed for enrolling the YubiKey for LUKS2 unlocking
	g_p11_module=$(dpkg -L ykcs11 | grep 'libykcs11.so$')

	install -d -m 0755 /usr/share/p11-kit/modules
	cat <<- EOF > /usr/share/p11-kit/modules/ykcs11.module
		module: $g_p11_module
		label: YubiKey PIV
	EOF
	#endregion

	#region Read the signing certificate and private-key URI
	install -d -m 0700 "$KEYS_DIR"

	touch "$SIGNING_CERTIFICATE_DER"

	pkcs11-tool --module "$g_p11_module" --read-object --type cert --id "$SIGNING_OBJECT_ID" --output-file "${SIGNING_CERTIFICATE_DER}"

	l_signing_private_key_uri=$(pkcs11-tool --module "$g_p11_module" --list-objects --id="$SIGNING_OBJECT_ID" --type privkey --pin "$piv_pin" | grep -o "pkcs11:.*")

	openssl x509 -in "${SIGNING_CERTIFICATE_DER}" -outform PEM -out "${SIGNING_CERTIFICATE_PEM}"
	#endregion

	#region Configure UKI and initramfs generation
	install -d -m 0755 /etc/kernel

	cat <<-EOF > /etc/kernel/install.conf
		layout=uki
		initrd_generator=dracut
		uki_generator=ukify
	EOF

	install -d -m 0755 /etc/dracut.conf.d
	cat <<- 'EOF' > /etc/dracut.conf.d/dracut.conf
		#stdloglvl="7"
		add_dracutmodules+=" bash crypt plymouth drm "
		add_dracutmodules+=" tpm2-tss crypt systemd-cryptsetup "
	EOF
	#endregion

	#region Define the TPM service account (Debian #1056665 / #1100919)
	install -d -m 0755 /etc/sysusers.d/
 	echo 'u tss - "TPM2 Software Stack user" /var/lib/tpm' > /etc/sysusers.d/tpm2-tss.conf
 	echo 'g tss -' >> /etc/sysusers.d/tpm2-tss.conf
	#endregion

	#region Configure DKMS module signing
	install -d -m 0755 /etc/dkms/framework.conf.d

	cat <<- EOF > /etc/dkms/framework.conf.d/signing.conf
		mok_signing_key="${l_signing_private_key_uri}"
		mok_certificate="${SIGNING_CERTIFICATE_DER}"
		sign_file="/etc/dkms/sign_helper.sh"
	EOF
	#endregion

	#region Write the DKMS signing helper
	install -d -m 0755 /etc/dkms
	cat <<- EOF > /etc/dkms/sign_helper.sh
		#!/usr/bin/bash

		export PKCSPIN=\$(/etc/kernel/scripts/piv_pin_helper.sh)

		/lib/modules/"\$kernelver"/build/scripts/sign-file "\$1" "\$2" "\$3" "\$4"
	EOF
	chmod +x /etc/dkms/sign_helper.sh
	#endregion

	#region Copy the signing certificate to the ESP for manual enrollment
	install -d -m 0755 "/boot/efi/EFI/secureboot"
	cp  "${SIGNING_CERTIFICATE_DER}" "/boot/efi/EFI/secureboot/mok-cert.der"
	#endregion

	#region Configure UKI signing with the YubiKey
	install -d -m 0755 /etc/kernel
	cat <<- EOF > /etc/kernel/uki.conf
		[UKI]
		SecureBootSigningTool=systemd-sbsign
		SigningProvider=pkcs11
		SignKernel=false
		SecureBootPrivateKey=${l_signing_private_key_uri}
		SecureBootCertificate=${SIGNING_CERTIFICATE_PEM}
		Cmdline=@/etc/kernel/cmdline

		# Optional: also for PCR signing (Measured Boot)
		# [PCRSignature:initrd]
		# PCRPrivateKey=pkcs11:object=Private key for Digital Signature;type=private
		# Phases=enter-initrd		
	EOF
	#endregion

	#region Write the PIV PIN cache helper
	install -d -m 0755 /etc/kernel/scripts
	cat <<- EOF > /etc/kernel/scripts/piv_pin_helper.sh
		#!/usr/bin/bash

		KEY_NAME=${PIV_PIN_KEY_NAME}

		KEY_ID=\$(keyctl search @s user "\$KEY_NAME" 2>/dev/null)

		if [[ -z "\$KEY_ID" ]]; then
			
			piv_pin=\$(dialog --keep-tite --insecure --title "SecureBoot signing" --passwordbox "\nEnter PIV PIN:" 9 40 2>&1 </dev/tty >/dev/tty)

			KEY_ID=\$(keyctl add user "\$KEY_NAME" "\$piv_pin" @s)
		fi

		keyctl print "\$KEY_ID"
	EOF
	chmod +x /etc/kernel/scripts/piv_pin_helper.sh
	#endregion

	#region Configure the OpenSSL PKCS#11 provider
	install -d -m 0755 /etc/ssl/openssl.cnf.d

	echo ".include /etc/ssl/openssl.cnf.d/" >> /etc/ssl/openssl.cnf

	cat <<- EOF > /etc/ssl/openssl.cnf.d/ykcs11.conf
		openssl_conf = openssl_init

		[openssl_init]
		providers = provider_sect

		[provider_sect]
		default = default_sect
		pkcs11 = pkcs11_sect

		[default_sect]
		activate = 1

		[pkcs11_sect]
		module = /usr/lib/x86_64-linux-gnu/ossl-modules/pkcs11.so
		pkcs11-module-cache-pins = cache
		pkcs11-module-login-behavior = auto
		#pkcs11-module-cache-sessions = 5
		pkcs11-module-token-pin = \$ENV::PKCSPIN
		activate=1
	EOF
	#endregion

	#region Install the UKI generation hook
	install -d -m 0755 /etc/kernel/postinst.d
	cat <<- 'EOF' > /etc/kernel/postinst.d/90-kernel-install
		#!/bin/sh
		set -eu
		export PKCSPIN=$(/etc/kernel/scripts/piv_pin_helper.sh)
		kernel-install add "$1" "/boot/vmlinuz-$1"
	EOF
	chmod +x /etc/kernel/postinst.d/90-kernel-install
	#endregion

	#region Install the fallback boot hints hook
	cat <<-'PLUGIN' > /etc/kernel/postinst.d/99-hints-update
		#!/bin/bash
		cd /boot/efi/EFI/Linux/
		ls *.efi -1 | sort -t'-' -k2 -V -r | awk -F'[-+]' '{print $0",Debian "$2",,Installed by devoid"}' | iconv -t UTF-16LE > BOOTX64.CSV
	PLUGIN
	chmod +x /etc/kernel/postinst.d/99-hints-update
	#endregion

	#region Divert Debian's dracut hook to use the UKI generation hook
	dpkg-divert --local --rename --add /etc/kernel/postinst.d/dracut
	#endregion

	#region Install the kernel and boot image tools
		DEBIAN_FRONTEND=noninteractive \
		apt install -yqq --autoremove --purge  -o Dpkg::Progress-Fancy=1   \
		plymouth plymouth-themes \
		systemd-ukify systemd-cryptsetup dracut \
		cryptsetup \
		firmware-linux-free firmware-linux-nonfree firmware-atheros \
		shim-unsigned \
		linux-image-amd64  
	#endregion

	#region Select the Plymouth theme
	plymouth-set-default-theme "$DEFAULT_PLYMOUTH_THEME"
	#endregion

	#region Sign and install the fallback bootloader
	# UEFIs can be unreliable in many ways so we will install a fallback bootloader in the ESP
	# that will scan for .CVS files and boot the first one it finds, which will be our UKI.
    # apt install shim-unsigned -yqq --no-install-recommends -o Dpkg::Progress-Fancy=1
    l_fallback=$(dpkg -L shim-unsigned | grep fbx64)

	install -d -m 755 /boot/efi/EFI/BOOT/
	
	/usr/lib/systemd/systemd-sbsign sign --private-key "${l_signing_private_key_uri}" \
		--certificate "${SIGNING_CERTIFICATE_PEM}" \
		--private-key-source provider:pkcs11 \
		"$l_fallback" --output /boot/efi/EFI/BOOT/BOOTX64.EFI

	#endregion

	#region Install DKMS and its signing test module
	apt install -yqq --autoremove --purge  -o Dpkg::Progress-Fancy=1 \
	 	dkms linux-headers-amd64 \
	 	dkms-test-dkms
	#endregion

	#region Install networking and maintenance tools
	apt install -yqq --autoremove --purge  -o Dpkg::Progress-Fancy=1 --no-install-recommends \
        network-manager usbutils nano vim iputils-ping network-manager-tui wpasupplicant netctl systemd-resolved tasksel
	#endregion

	#region Enroll Secure Boot db, KEK and PK (PK last)
	apt install -y --no-install-recommends -o Dpkg::Progress-Fancy=1 efitools uuid-runtime expect

	l_owner_guid=$(uuidgen --random)
	echo "$l_owner_guid" > "$SIGNING_KEY_GUID"

	cert-to-efi-sig-list -g "$l_owner_guid" "$SIGNING_CERTIFICATE_PEM" "$SIGNING_KEY_ESL" 

	# sbsiglist takes one binary digest at a time; concatenate the resulting ESLs.
	l_driver_digest=$(mktemp)
	while read -r l_driver_hash; do
		printf '%s' "$l_driver_hash" | xxd -r -p > "$l_driver_digest"
		sbsiglist --owner "$l_owner_guid" --type sha256 \
			--output "$l_driver_digest.esl" "$l_driver_digest"
		cat "$l_driver_digest.esl"
	done < "$SERVICE_DRIVERS_HASHES" > "$SERVICE_DRIVERS_ESL"
	rm "$l_driver_digest" "$l_driver_digest.esl"

	# efitools now supports openssl 3.0 providers
	sign-efi-sig-list -e pkcs11 \
	-k "$l_signing_private_key_uri" \
	-c "$SIGNING_CERTIFICATE_PEM" \
	PK "$SIGNING_KEY_ESL" "$PK_AUTH"

	efi-updatevar -e -f "$SIGNING_KEY_ESL" db
	efi-updatevar -a -e -f "$SERVICE_DRIVERS_ESL" db
	efi-updatevar -e -f "$SIGNING_KEY_ESL" KEK
	efi-updatevar -f "$PK_AUTH" PK
	#endregion

	#region Create the swapfile
	fallocate -l "$DEFAULT_SWAP_SIZE" /swapfile
	chmod 600 /swapfile
	mkswap /swapfile
	#endregion

	#region Write the post-boot TPM enrollment helper
	cat <<- EOF > /root/tpm-enroll.sh
		#!/bin/bash
		/usr/bin/systemd-cryptenroll ${p_physical_root_partition} --tpm2-device=auto --tpm2-pcrs="$DEFAULT_TPM_PCRS" --wipe-slot=tpm2  --unlock-fido2-device=auto
	EOF
	chmod 700 /root/tpm-enroll.sh
	#endregion

	#region Write the FIDO2 home creation helper
	apt install systemd libfido2-1 fido2-tools systemd-homed -y -o Dpkg::Progress-Fancy=1
	cat <<- EOF > /root/create_homed_user.sh
		#!/bin/bash
		systemctl enable --now systemd-homed

		homectl create \$1 \\
		  --storage=luks \\
		  --fido2-device=auto \\
		  --fs-type=ext4 \\
		  --disk-size=$DEFAULT_HOMED_DISK_SIZE \\
		  --fido2-with-client-pin=yes \\
		  --fido2-with-user-presence=yes \\
		  --recovery-key=yes

		homectl activate \$1
	EOF
	chmod 700 /root/create_homed_user.sh
	#endregion

}

#endregion

#region Cleanup
cleanup()
{

 	echo "Cleaning up..."

 	sync

 	[ -d "${TARGET}" ] && umount -R "${TARGET}"

 	cryptsetup close "${LUKS_ROOT_DEVICE}"


 	exit 0
}
#endregion


#region Entry point
trap 'echo "ERROR: Script failed at line $LINENO."; cleanup' SIGINT SIGTERM SIGHUP ERR 

if [ $# -lt 1 ]; then # no arguments, run as host

	host_side_code 

	cleanup

else
	if [ "$1" = "target" ]; then
		target_side_code "$2"
	fi
fi
#endregion
