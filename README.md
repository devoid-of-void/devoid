# devoid
**d**evoid is **e**xalted and very **o**pinionated **i**nstaller for **d**ebian

it is also

**d**evoid of **e**vanescent **v**alue **o**ptions; **i**ntentionally and *d*eliberately.

**WARNING**: devoid will make your computer devoid of all data, windows, purpose and proper functioning.  **devoid** is not intended for production use of any sort or for new and inexperienced linux users. If your computer doesn't end up bricked, you might actually get debian installed on it. Maybe. Proceed at your own risk, you have been warned. 

## Rationale
I was debian user, one way or another, since 1999, and since then there  has never been an installer that could setup the system the way I like it. Sure, all the software was there, but it required endless tinkering with technologies I wasn't interested in understanding fully, so I was usually leaving the system in its default state. 

Unfortunately(sic!), I was granted the time to do things the way I like it, fully and without compromise. devoid is the result: it is installer that fits my needs and matches my preferences to the tiniest detail. It was an excuse to finally learn about various technologies, and how to use them. I'm making devoid public in case someone else finds it useful. It is not an attempt to replace the official installer nor is it an attempt to achieve anything in particular. It is made for those like me who use linux, and linux only, because they enjoy it. Everything else is circumstantial.

## Security

Secure boot allows only trusted software to boot, where trusted traditionally means signed with Microsoft's keys. For that reason, linux boot loaders are signed by Microsoft, called shims, to allow linux to boot. However, whether or not Microsoft keeps their keys safe, and in what measure, is unknown and relies on your trust that Microsoft acts in good faith. Furthermore, there are platform keys, provided by UEFI/motherboard manufacturers that can be trusted less than microsoft, which can be used to sign bootable software. 

For pure linux computer neither type of keys is required: devoid requires complete removal of all keys present in UEFI database prior to installation. This can brick some motherboards so proceed with caution. devoid signs all bootable components with a private key residing on a yubikey which cannot be extracted in any way or used without physical presence confirmation. 

Kernel and initramfs are packed into UKI, and signed as well all out of tree modules and a fallback bootloader which is regretfully required for older UEFI but which will be removed in near future. By doing so, no software can be signed without user's consent and consequently boot. 

However, secure boot can be disabled in which case the whole scheme is useless. To prevent that from happening, the data on the hard drive is on encrypted LUKS2 volume decrypted automatically by TPM2 pcr 7. This means that if any SecureBoot setting is tempered with, the drive can't be decrypted. 

This scheme ensures that only software signed with owner's key can boot, and that the data is safe at rest. However is someone gets ahold of the computer while booted, data can be extracted in principle. for that reason, user data is on a homed luks2 encrypted volume unlocked with the same yubikey. This also makes user data easier to backup for install it resides in a single file.

While the above security scheme is reasonably safe, it can't protect the computer against state level actors, or actors that can use coercion to get security keys:

![](https://imgs.xkcd.com/comics/security.png)

Also, nothing stops you from installing a virus of some sort yourself, so make sure your online behavior is reasonable. To stop users from mixing things up, despite being as counterculture as it gets, sudo is not used. you have to open a session with 'su -' in a terminal to do your system administration. As I said devoid is opinionated. sudecription requires the same yubikey to let you open the session. 

Finally, backups are absolutely necessary. Future version of devoid will refuse to install if you don't have a backup drive, and/or offsite backup solution.

## Miscellany

- why yubikey?
	- I have no other security keys, and I chose Yubi because they made a genuine contribution to linux.
- why no swap?
	- I simply forgot about it, I got 128GB of RAM... I will add it soon though.
- why no partitions (other than EFI)?
	- I see no point in it; it makes dividing the drive into fixed sized blocks that will never be efficiently used; some free space will always remain unused. By putting everything on a single partition, the resizing of any sort is not required.
- why XFS?
	- Sentimental reasons.
- why UKI?
	- to be able to sign the bootable image without any dangling components that can be compromised.
- why dracut
	- coolest option IMHO.
- why not btrfs?
	- No need for volume management, encryption not native
- why not ZFS
	- Licence not compatible, nightmare to setup as boot, and no particular gain. If you use it for data, you can, but not on the system drive.
- why no options of any kind?
	- All my life I was doing things "just in case". Well, "the case" never arrived in 99% of the time, so I picked options accordingly. 


## How to use

You will need yubikey with PIV app (5C), configured with PIV  and FIDO2 NIPs and touch confirmation enabled.

Make sure you have your data safe on some sort backup media or cloud storage. There will be none left as soon as you start devoid.

Make yourself a ventoy drive, leave some space on it (option in ventoy), drop devoid.sh on it along with your favorite live cd iso. Go to UEFI, remove all the keys, and put the system in custom mode. insert your yubikey, boot your iso on ventoy, connect to your network, get your drive id (use lsblk), and run devoid.sh. answer the questions, and watch your yubikey. If you don't confirm your presence in time, you will have to start over.

Once its finished, reboot. There will be enroll_tpm.sh script in /root you need to run to enable TPM2 decryption, otherwise you'll have to use your YubiKey. To create users there is a create user scriplet in /root that only accepts user name as a parameter. 

Finally, start tasksel to choose your desktop environment if required, install drivers as needed and reboot.



devoid is an exalted and very opinionated installer for debian.

It is also devoid of evanescent value options; intentionally and deliberately.

WARNING: devoid will make your computer devoid of all data, windows, purpose, and proper functioning. devoid is not intended for production use of any sort or for new and inexperienced linux users. If your computer doesn't end up bricked, you might actually get debian installed on it. Maybe. Proceed at your own risk; you have been warned.

### Rationale

I was a debian user, one way or another, since 1999, and since then there has never been an installer that could set up the system the way I like it. Sure, all the software was there, but it required endless tinkering with technologies I wasn't interested in understanding fully, so I was usually leaving the system in its default state.

Unfortunately (sic!), I was granted the time to do things the way I like them, fully and without compromise. devoid is the result: it is an installer that fits my needs and matches my preferences to the tiniest detail. It was an excuse to finally learn about various technologies and how to use them. I'm making devoid public in case someone else finds it useful. It is not an attempt to replace the official installer, nor is it an attempt to achieve anything in particular. It is made for those like me who use linux, and linux only, because they enjoy it. Everything else is circumstantial.

### Security

Secure boot allows only trusted software to boot, where trusted traditionally means signed with Microsoft's keys. For that reason, linux boot loaders are signed by Microsoft, called shims, to allow linux to boot. However, whether or not Microsoft keeps their keys safe, and in what measure, is unknown and relies on your trust that Microsoft acts in good faith. Furthermore, there are platform keys, provided by UEFI/motherboard manufacturers that can be trusted less than Microsoft, which can be used to sign bootable software.

For a pure linux computer, neither type of key is required: devoid requires the complete removal of all keys present in the UEFI database prior to installation. This can brick some motherboards, so proceed with caution. devoid signs all bootable components with a private key residing on a YubiKey, which cannot be extracted in any way or used without physical presence confirmation.

The kernel and initramfs are packed into a UKI and signed, as well as all out-of-tree modules and a fallback bootloader which is regretfully required for older UEFI but which will be removed in the near future. By doing so, no software can be signed without the user's consent and consequently boot.

However, secure boot can be disabled, in which case the whole scheme is useless. To prevent that from happening, the data on the hard drive is on an encrypted LUKS2 volume decrypted automatically by TPM2 pcr 7. This means that if any SecureBoot setting is tampered with, the drive can't be decrypted.

This scheme ensures that only software signed with the owner's key can boot, and that the data is safe at rest. However, if someone gets ahold of the computer while booted, data can be extracted in principle. For that reason, user data is on a homed LUKS2 encrypted volume unlocked with the same YubiKey. This also makes user data easier to back up, because it resides in a single file.

While the above security scheme is reasonably safe, it can't protect the computer against state-level actors, or actors that can use coercion to get security keys.

![](https://imgs.xkcd.com/comics/security.png)

Also, nothing stops you from installing a virus of some sort yourself, so make sure your online behavior is reasonable. To stop users from mixing things up, despite being as counterculture as it gets, sudo is not used. You have to open a session with `su -` in a terminal to do your system administration. As I said, devoid is opinionated. `su` authentication requires the same YubiKey to let you open the session.

Finally, backups are absolutely necessary. Future versions of devoid will refuse to install if you don't have a backup drive and/or an offsite backup solution.

### Miscellany

- **Why YubiKey?** I have no other security keys, and I chose Yubi because they made a genuine contribution to linux.
    
- **Why no swap?** I simply forgot about it, I got 128GB of RAM... I will add it soon though.
    
- **Why no partitions (other than EFI)?** I see no point in it; it makes dividing the drive into fixed-sized blocks that will never be efficiently used; some free space will always remain unused. By putting everything on a single partition, resizing of any sort is not required.
    
- **Why XFS?** Sentimental reasons.
    
- **Why UKI?** To be able to sign the bootable image without any dangling components that can be compromised.
    
- **Why dracut?** Coolest option IMHO.
    
- **Why not btrfs?** No need for volume management, encryption not native.
    
- **Why not ZFS?** License not compatible, nightmare to set up as boot, and no particular gain. If you use it for data, you can, but not on the system drive.
    
- **Why no options of any kind?** All my life I was doing things "just in case". Well, "the case" never arrived 99% of the time, so I picked options accordingly.
    

### How to use

You will need a YubiKey with the PIV app (5C), configured with PIV and FIDO2 PINs, and touch confirmation enabled.

Make sure you have your data safe on some sort of backup media or cloud storage. There will be none left as soon as you start devoid.

Make yourself a Ventoy drive, leave some space on it (option in Ventoy), drop `devoid.sh` on it along with your favorite live CD iso. Go to UEFI, remove all the keys, and put the system in custom mode. Insert your YubiKey, boot your iso on Ventoy, connect to your network, get your drive id (use `lsblk`), and run `devoid.sh`. Answer the questions, and watch your YubiKey. If you don't confirm your presence in time, you will have to start over.

Once it's finished, reboot. There will be an `enroll_tpm.sh` script in `/root` you need to run to enable TPM2 decryption; otherwise, you'll have to use your YubiKey. To create users, there is a create-user scriptlet in `/root` that only accepts the user name as a parameter.

Finally, start tasksel to choose your desktop environment if required, install drivers as needed, and reboot.


