#!/bin/bash
set -euo pipefail
# set -x
# signing slot is 9c
# if the YubiKey has a pre-generated key in slot 9c, this will overwrite it without warning, so be careful with this line
# use only if you haven't generated a key in slot 9c before, or if you don't mind losing the existing key and any certificates associated with it
# yubico-piv-tool -s9c --pin="$p_PIV_PIN" -agenerate --algorithm RSA2048 --touch-policy=cached -averify-pin
# LUKS key/certificate is in 9a
# yubico-piv-tool -s9a -ARSA2048 --pin="$p_PIV_PIN" -averify-pin -agenerate --touch-policy=cached -opub.pem
# yubico-piv-tool -s9a -S'/CN=luks2-key/OU=voids/O=debian.org/' --pin="$p_PIV_PIN" -averify-pin -aselfsign -ipub.pem -opub.crt
# yubico-piv-tool -s9a --pin="$p_PIV_PIN" -averify-pin -aimport-certificate -ipub.crt

#c_disk="/dev/disk/by-id/virtio-target"
c_disk="/dev/disk/by-id/ata-KINGSTON_RBU-SNS8152S3256GG2_50026B7369011B0A"

p_debian_version="forky"

c_target="/mnt/target"
c_signing_certificate_der="/etc/kernel/keys/signing-certificate.der"
c_signing_certificate_pem="/etc/kernel/keys/signing-certificate.pem"
c_luks_root_device=/dev/mapper/cryptoroot
c_credentials_directory="/run/credentials"
c_piv_pin_key_name="devoid:piv-pin"

host_side_code()
{
	#region setup the host side environment 
	apt update

	apt install -yqq --no-install-recommends --autoremove --purge -o Dpkg::Progress-Fancy=1 \
		dialog gdisk uuid-runtime parted dosfstools xfsprogs mmdebstrap cryptsetup \
		systemd-cryptsetup systemd-container efibootmgr \
		yubico-piv-tool ykcs11 \
		opensc opensc-pkcs11 p11-kit p11-kit-modules pcscd pcsc-tools \
		tpm2-tools efitools\
		libpam-u2f pamu2fcfg expect \
		gpg
		# for debugging purposes
		# apt install sshfs fuse openssh-server
		systemctl enable pcscd
		systemctl start pcscd
		dialog --keep-tite  --title "Restarting pcscd" --msgbox "\nPlease replug your YubiKey" 7 60
	#endregion

	#region Check prerequisites: disks, YubiKey, TPM
	l_disk=$(dialog --keep-tite  --stdout --inputbox "Enter installation disk:" 8 50 "${c_disk}")
	echo "Selected disk: $l_disk"
	error_message=""
	no_messages=0
	if [ ! -e "$l_disk" ]; then
		error_message+="\nInstallation disk not found.\n" >&2
		(( no_messages += 1 ))
	fi

	if ! lsusb | grep -q "1050:0407"; then
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

	#region Partition the target drive
	sgdisk --zap-all "${l_disk}"
	l_efi_system_partition_uuid=$(uuidgen)
	sgdisk --new=1:2048:+1G  \
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

	#region Format ESP partition
	l_efi_system_partition="/dev/disk/by-partuuid/${l_efi_system_partition_uuid}"
	wipefs -a "${l_efi_system_partition}"
	mkfs.vfat -F32 -n EFI "${l_efi_system_partition}"

	l_physical_root_partition="/dev/disk/by-partuuid/${l_root_partition_uuid}"

	udevadm trigger --subsystem-match=block
	udevadm settle
	#endregion

	#region Setup LUKS2 on root partition: passphrase, YubiKey and TPM2

	# mkdir -p ignores -m for intermediate directories; set mode explicitly on the final
	install -d -m 0700 "$c_credentials_directory"

	luks2_pass=$(dialog --keep-tite --insecure --title "LUKS2 recovery" --passwordbox "\nEnter LUKS2 passphrase:" 9 40 2>&1 </dev/tty >/dev/tty)
	echo -n "$luks2_pass" | cryptsetup luksFormat "$l_physical_root_partition" --type luks2 --batch-mode --key-file=-

	echo -n "$luks2_pass" | cryptsetup luksOpen "$l_physical_root_partition" cryptoroot --key-file=-

	echo -n "$luks2_pass" | systemd-creds encrypt --name=cryptenroll.passphrase - $c_credentials_directory/cryptenroll.passphrase
	unset luks2_pass

	fido2_pin=$(dialog --keep-tite --insecure --title "FIDO2 to LUKS2 enrollment" --passwordbox "\nEnter FIDO2 PIN:" 9 40 2>&1 </dev/tty >/dev/tty)
	echo -n "$fido2_pin" | systemd-creds encrypt --name=cryptenroll.fido2-pin - $c_credentials_directory/cryptenroll.fido2-pin

	systemd-run --pty --wait --collect 	\
	 			--property="LoadCredentialEncrypted=cryptenroll.fido2-pin:$c_credentials_directory/cryptenroll.fido2-pin" \
				--property="LoadCredentialEncrypted=cryptenroll.passphrase:$c_credentials_directory/cryptenroll.passphrase" \
		/usr/bin/systemd-cryptenroll --fido2-device=auto "$l_physical_root_partition"

	#if no tpm2 token is enrolled, systemd will fail to boot without asking for password, so here's one that will fallback to passphrase
	systemd-run --pty --wait --collect 	\
	 			--property="LoadCredentialEncrypted=cryptenroll.passphrase:$c_credentials_directory/cryptenroll.passphrase" \
		/usr/bin/systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --wipe-slot=tpm2 "$l_physical_root_partition"

	shred -u "$c_credentials_directory/cryptenroll.fido2-pin"
	shred -u "$c_credentials_directory/cryptenroll.passphrase"


	l_luks_uuid=$(cryptsetup luksUUID "${l_physical_root_partition}")
	l_root_partition=${c_luks_root_device}

	udevadm trigger --subsystem-match=block
	udevadm settle
	#endregion

	#region Format and mount root partition
	l_rootfs_uuid=$(uuidgen)
	wipefs -a "${l_root_partition}"
	mkfs.xfs -m uuid="${l_rootfs_uuid}" -L root "${l_root_partition}"

	# Temporary mountpoint
	mkdir -p "${c_target}"
	mount "${l_root_partition}" "${c_target}"

	# Persistent directories
	install -d -m 0755 "${c_target}/home"
	install -d -m 0755 "${c_target}/etc"

	# ESP mountpoint
	mkdir -p "${c_target}/boot/efi"
	mount "${l_efi_system_partition}" "${c_target}/boot/efi" -o umask=077
	#endregion

	#region Setup fstab    
	# GPT root partition (PARTUUID=<root-partuuid>)
	#     └─ LUKS2 container (UUID=<luks-uuid>)
	#         └─ /dev/mapper/cryptoroot
	#             └─ XFS filesystem (UUID=<rootfs-uuid>)

	echo "/dev/mapper/luks-${l_luks_uuid} / xfs defaults 0 1" > "${c_target}"/etc/fstab
	echo "PARTUUID=${l_efi_system_partition_uuid} /boot/efi vfat defaults,umask=077 0 2" >> "${c_target}"/etc/fstab
	#endregion

	#region Debootstrap the base system
	unshare -m mmdebstrap --mode=root --variant=apt "${p_debian_version}" "${c_target}" \
		--components="main contrib non-free non-free-firmware"  \
		--skip=check/empty 
	#endregion
	
	#region Setup kernel cmdline 
	install -d -m 0755 "${c_target}"/etc/kernel
	# for debug shell add    "rd.debug rd.shell rd.break=pre-mount" 
	l_kernel_command_line="quiet splash rw root=UUID=${l_rootfs_uuid} rootfstype=xfs rd.luks.uuid=${l_luks_uuid} rootflags=rw "

	l_kernel_command_line+=" rd.luks.options=${l_luks_uuid}=pkcs11-uri=auto,tpm2-device=auto "

	echo "$l_kernel_command_line" > "${c_target}"/etc/kernel/cmdline 
	#endregion

	#region Set hostname
	l_hostname=$(dialog --keep-tite  --stdout --inputbox "Enter hostname:" 8 50 "devoid-forky")
	echo "127.0.1.1 $l_hostname" >> "${c_target}"/etc/hosts
	echo "$l_hostname" > "${c_target}"/etc/hostname
	#endregion


	#region set pam configuration for fido2 login
	echo "Please touch the YubiKey to enable passwordless root login..."
	expect <<- EOF > $c_credentials_directory/u2f_keys
		spawn pamu2fcfg --username=root --origin=pam://$l_hostname --pin-verification
		expect {
			"Enter PIN" { send "$fido2_pin\r" }
		}
		expect eof
	EOF

	unset fido2_pin
	#endregion

	#region copy root's pam credentials for later use in the container
	install -d -m 0700 "${c_target}/etc/u2f_mappings"
	grep "root" $c_credentials_directory/u2f_keys > "${c_target}/etc/u2f_mappings/u2f_keys"
	shred -u $c_credentials_directory/u2f_keys
	#endregion

	#region Start target side script in nspawn container
	
	# echo systemd-nspawn  --bind=devoid.sh:/devoid.sh \
	# 				--directory="${c_target}" \
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
					--directory="${c_target}" \
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

	#region delete all boot entries except the testing environment called 'debugging' 
	# efibootmgr | grep -v -i "debugging" | awk '/^Boot[0-9]/{print substr($1,5,4)}' | xargs -n1 efibootmgr -B -b
	# l_deb=$(efibootmgr | grep -i "debian" | awk '/^Boot[0-9]/{print substr($1,5,4)}' )
	#endregion

	#region delete all boot entries 
	efibootmgr | grep -v -i "debugging" | awk '/^Boot[0-9]/{print substr($1,5,4)}' | xargs -n1 efibootmgr -B -b
	# #endregion

	#region create new entry for our UKI
	efibootmgr --create \
		--disk $l_disk \
		--part 1 \
		--label "Debian GNU/Linux installed by devoid" \
		--loader "EFI/BOOT/BOOTX64.EFI" \
		--bootnum 0000 \
		--bootorder 0000 \
		--bootnext 0000
	#endregion

	#region Copy NetworkManager configs, if any, to preserve wifi settings 
	cp /etc/NetworkManager/system-connections/* "${c_target}/etc/NetworkManager/system-connections/" || true
	#endregion

}

target_side_code()
{
	p_physical_root_partition=$1

	#region get admin user info
	apt update 
	apt-get install -y dialog -o Dpkg::Progress-Fancy=1 

	#region Setting up the basics: locale, timezone, keyboard
	export DEBIAN_FRONTEND=dialog

	apt-get install -y locales tzdata keyboard-configuration adduser -o Dpkg::Progress-Fancy=1 
	#endregion

	#region Setup root
	apt-get install -y git -o Dpkg::Progress-Fancy=1  curl zsh sudo sudo ssh sshfs bash dialog libpam-u2f pamu2fcfg 

	root_pass=$(head -c 500 /dev/urandom | tr -dc 'A-Za-z0-9!@#$%' | head -c 12)

	echo "root:${root_pass}" | chpasswd

	dialog --title "Root passphrase" --msgbox "\n$root_pass\n\nThis is your root password. Keep it somewhere safe." 10 60

	unset root_pass

	sed -i '1i auth	 sufficient	 pam_u2f.so authfile=/etc/u2f_mappings/u2f_keys cue pinverification=1 userpresence=1' /etc/pam.d/su
	sed -i '1i auth	 sufficient	 pam_u2f.so authfile=/etc/u2f_mappings/u2f_keys cue pinverification=1 userpresence=1' /etc/pam.d/login

	sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
	sed -i 's/ZSH_THEME=".*"/ZSH_THEME="risto"/' ~/.zshrc
	chsh -s "$(which zsh)"
	#endregion
	
	#region Install signing tools for secureboot and DKMS
	apt-get install -y keyutils gnutls-bin openssl mokutil sbsigntool tpm2-tools tpm2-tss libgcrypt20 -o Dpkg::Progress-Fancy=1 
	#endregion

	#region get and cache the PIV PIN for later use in DKMS module signing and secureboot signing
	piv_pin=$(dialog --keep-tite --insecure --title "DKMS signing" --passwordbox "\nEnter PIV PIN:" 9 40 2>&1 </dev/tty >/dev/tty)
	keyctl add user "$c_piv_pin_key_name" "$piv_pin" @s
	export PKCSPIN=$piv_pin
	#endregion

	#region Setup security keys and tools for enrolling YubiKey for LUKS2 unlocking and secureboot, and for signing DKMS modules
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

	#region Setup keys for secureboot and DKMS
	install -d -m 0700 "/etc/kernel/keys"
	
	install -d -m 0700 -- "$(dirname -- "$c_signing_certificate_der")"

	touch "$c_signing_certificate_der"

	pkcs11-tool --module "$g_p11_module" --read-object --type cert --id 02 --output-file "${c_signing_certificate_der}"

	l_signing_private_key_uri=$(pkcs11-tool --module "$g_p11_module" --list-objects --id=02 --type privkey --pin "$piv_pin" | grep -o "pkcs11:.*")

	openssl x509 -in "${c_signing_certificate_der}" -outform PEM -out "${c_signing_certificate_pem}"
	#endregion

	#region Configure initramfs generation
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

	#region temporary fix while waiting for #1056665 / #1100919 to be resolved
	install -d -m 0755 /etc/sysusers.d/
 	echo 'u tss - "TPM2 Software Stack user" /var/lib/tpm' > /etc/sysusers.d/tpm2-tss.conf
 	echo 'g tss -' >> /etc/sysusers.d/tpm2-tss.conf
	#endregion

	#region Configure DKMS to sign modules with yubikey
	install -d -m 0755 /etc/dkms/framework.conf.d

	cat <<- EOF > /etc/dkms/framework.conf.d/signing.conf
		mok_signing_key="${l_signing_private_key_uri}"
		mok_certificate="${c_signing_certificate_der}"
		sign_file="/etc/dkms/sign_helper.sh"
	EOF
	#endregion

	#region Create signing helper script, we need to cache the piv pin ourselves
	install -d -m 0755 /etc/dkms
	cat <<- EOF > /etc/dkms/sign_helper.sh
		#!/usr/bin/bash

		export PKCSPIN=\$(/etc/kernel/scripts/piv_pin_helper.sh)

		/lib/modules/"\$kernelver"/build/scripts/sign-file "\$1" "\$2" "\$3" "\$4"
	EOF
	chmod +x /etc/dkms/sign_helper.sh
	#endregion

	#region make the certificate easy to enroll manually via UEFI if needed
	install -d -m 0755 "/boot/efi/EFI/secureboot"
	cp  "${c_signing_certificate_der}" "/boot/efi/EFI/secureboot/mok-cert.der"
	#endregion

	#region Configure UKI signing to use yubikey
	install -d -m 0755 /etc/kernel
	cat <<- EOF > /etc/kernel/uki.conf
		[UKI]
		SecureBootSigningTool=systemd-sbsign
		SigningProvider=pkcs11
		SignKernel=false
		SecureBootPrivateKey=${l_signing_private_key_uri}
		SecureBootCertificate=${c_signing_certificate_pem}
		Cmdline=@/etc/kernel/cmdline

		# Optional: also for PCR signing (Measured Boot)
		# [PCRSignature:initrd]
		# PCRPrivateKey=pkcs11:object=Private key for Digital Signature;type=private
		# Phases=enter-initrd		
	EOF
	#endregion

	#region Create signing helper script, we need to cache the piv pin ourselves
	install -d -m 0755 /etc/kernel/scripts
	cat <<- EOF > /etc/kernel/scripts/piv_pin_helper.sh
		#!/usr/bin/bash

		KEY_NAME=${c_piv_pin_key_name}

		KEY_ID=\$(keyctl search @s user "\$KEY_NAME" 2>/dev/null)

		if [[ -z "\$KEY_ID" ]]; then
			
			piv_pin=\$(dialog --keep-tite --insecure --title "SecureBoot signing" --passwordbox "\nEnter PIV PIN:" 9 40 2>&1 </dev/tty >/dev/tty)

			KEY_ID=\$(keyctl add user "\$KEY_NAME" "\$piv_pin" @s)
		fi

		keyctl print "\$KEY_ID"
	EOF
	chmod +x /etc/kernel/scripts/piv_pin_helper.sh
	#endregion

	#region configure openssl 
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

	#region Setup kernel post install script to prepare and install UKI
	install -d -m 0755 /etc/kernel/postinst.d
	cat <<- 'EOF' > /etc/kernel/postinst.d/90-kernel-install
		#!/bin/sh
		set -eu
		export PKCSPIN=$(/etc/kernel/scripts/piv_pin_helper.sh)
		kernel-install add "$1" "/boot/vmlinuz-$1"
	EOF
	chmod +x /etc/kernel/postinst.d/90-kernel-install
	#endregion

	#region Setup kernel post install script to update bootloader hints
	cat <<-'PLUGIN' > /etc/kernel/postinst.d/99-hints-update
		#!/bin/bash
		cd /boot/efi/EFI/Linux/
		ls *.efi -1 | sort -t'-' -k2 -V -r | awk -F'[-+]' '{print $0",Debian "$2",,Installed by devoid"}' | iconv -t UTF-16LE > BOOTX64.CSV
	PLUGIN
	chmod +x /etc/kernel/postinst.d/99-hints-update
	#endregion

	#remove debian's rogue dracut hook which ignores uki/signing
	dpkg-divert --local --rename --add /etc/kernel/postinst.d/dracut
	#endregion

	#region Install kernel, initramfs packages, and UKI generators
		DEBIAN_FRONTEND=noninteractive \
		apt install -yqq --autoremove --purge  -o Dpkg::Progress-Fancy=1   \
		plymouth plymouth-themes \
		systemd-ukify systemd-cryptsetup dracut \
		cryptsetup \
		firmware-linux-free firmware-linux-nonfree firmware-atheros \
		shim-unsigned \
		linux-image-amd64  
	#endregion

	#region set Plymouth theme to solar
	plymouth-set-default-theme solar
	#endregion

	#region setup boot mechanisms
	# UEFIs can be unreliable in many ways so we will install a fallback bootloader in the ESP
	# that will scan for .CVS files and boot the first one it finds, which will be our UKI.
    # apt install shim-unsigned -yqq --no-install-recommends -o Dpkg::Progress-Fancy=1
    l_fallback=$(dpkg -L shim-unsigned | grep fbx64)

	install -d -m 755 /boot/efi/EFI/BOOT/
	
	/usr/lib/systemd/systemd-sbsign sign --private-key "${l_signing_private_key_uri}" \
		--certificate "${c_signing_certificate_pem}" \
		--private-key-source provider:pkcs11 \
		"$l_fallback" --output /boot/efi/EFI/BOOT/BOOTX64.EFI

	#endregion

	#region Install DKMS and test module generation and signing
	apt install -yqq --autoremove --purge  -o Dpkg::Progress-Fancy=1 \
	 	dkms linux-headers-amd64 \
	 	dkms-test-dkms
	#endregion

	#region Install network manager plus system utilities for debugging and maintenance
	apt install -yqq --autoremove --purge  -o Dpkg::Progress-Fancy=1 --no-install-recommends \
        network-manager usbutils nano vim iputils-ping network-manager-tui wpasupplicant netctl systemd-resolved tasksel
	#endregion

	#region Enroll the signing key to the UEFI db and KEK so that it can be used for secureboot and DKMS module signing 
	apt install -y --no-install-recommends -o Dpkg::Progress-Fancy=1 efitools uuid-runtime expect

	l_owner_guid=$(uuidgen --random)
	echo "$l_owner_guid" > $c_signing_certificate_pem.guid

	cert-to-efi-sig-list -g "$l_owner_guid" $c_signing_certificate_pem $c_signing_certificate_pem.esl 

	# its an ugly hack, but there's no point in wrestling with outdated efitools.
	# there is a patch for openssl 3.0 providers, but it hasn't been merged yet
	expect <<- EOF
		spawn sign-efi-sig-list -e pkcs11 \
		-k "$l_signing_private_key_uri" \
		-c "$c_signing_certificate_pem" \
		PK "$c_signing_certificate_pem.esl" "$c_signing_certificate_pem.auth"
		expect "pass phrase:"
		send "$PKCSPIN\r"
		expect "pass phrase:"
		send "$PKCSPIN\r"
		expect eof
	EOF

	efi-updatevar -e -f $c_signing_certificate_pem.esl db
	efi-updatevar -e -f $c_signing_certificate_pem.esl KEK
	efi-updatevar -f $c_signing_certificate_pem.auth PK
	#endregion

	#region Prepare TPM enrollment scriplet
	cat <<- EOF > /root/tpm-enroll.sh
		#!/bin/bash
		/usr/bin/systemd-cryptenroll ${p_physical_root_partition} --tpm2-device=auto --tpm2-pcrs=7 --wipe-slot=tpm2  --unlock-fido2-device=auto
	EOF
	chmod 700 /root/tpm-enroll.sh
	#endregion

	#region setup homed scriplet
	apt install systemd libfido2-1 fido2-tools systemd-homed -y -o Dpkg::Progress-Fancy=1
	cat <<- EOF > /root/create_homed_user.sh
		#!/bin/bash
		systemctl enable --now systemd-homed

		homectl create \$1 \\
		  --storage=luks \\
		  --fido2-device=auto \\
		  --fs-type=ext4 \\
		  --disk-size=20G \\
		  --fido2-with-client-pin=yes \\
		  --fido2-with-user-presence=yes \\
		  --recovery-key=yes

		homectl activate \$1
	EOF
	chmod 700 /root/create_homed_user.sh
	#endregion

}



cleanup()
{
 	#region Unmount target and clean up

 	echo "Cleaning up..."

 	sync

 	[ -d "${c_target}" ] && umount -R "${c_target}"

 	cryptsetup luksClose "${c_luks_root_device}"

	#endregion

 	exit 0
}


trap 'echo "ERROR: Script failed at line $LINENO."; cleanup' SIGINT SIGTERM SIGHUP ERR 

if [ $# -lt 1 ]; then # no arguments, run as host

	host_side_code 

	cleanup

else
	if [ "$1" = "target" ]; then
		target_side_code "$2"
	fi
fi


