# Evidence: raw command output

Captured 20 Oct 2026 04:07:46 UTC on webclub-os.

## Partition layout and filesystem UUIDs

```text
$ lsblk -o NAME,SIZE,FSTYPE,UUID,PARTUUID,MOUNTPOINTS /dev/sda
NAME           SIZE FSTYPE      UUID                                 PARTUUID                             MOUNTPOINTS
sda             20G                                                                                       
├─sda1         512M vfat        FB2D-2438                            a99b1c5a-d96c-449e-b634-8bb930d00e38 /boot/efi
├─sda2           1G ext4        d0bb7d1a-2d2b-4059-9c3b-ef19f40b668c d877bab7-4d29-4b1e-a8f9-dfc672697364 /boot
└─sda3        18.5G crypto_LUKS b552f692-3938-49ba-99c8-204fbfd004bc 19475771-7cf6-42da-9104-ef510b83a438 
  └─cryptroot 18.5G ext4        ef02d054-71ed-4235-aee4-ca7f99ef24f8                                      /
```

## blkid

```text
$ blkid /dev/sda1 /dev/sda2 /dev/sda3 /dev/mapper/cryptroot
/dev/sda1: UUID="FB2D-2438" BLOCK_SIZE="512" TYPE="vfat" PARTLABEL="ESP" PARTUUID="a99b1c5a-d96c-449e-b634-8bb930d00e38"
/dev/sda2: LABEL="boot" UUID="d0bb7d1a-2d2b-4059-9c3b-ef19f40b668c" BLOCK_SIZE="4096" TYPE="ext4" PARTLABEL="boot" PARTUUID="d877bab7-4d29-4b1e-a8f9-dfc672697364"
/dev/sda3: UUID="b552f692-3938-49ba-99c8-204fbfd004bc" TYPE="crypto_LUKS" PARTLABEL="root" PARTUUID="19475771-7cf6-42da-9104-ef510b83a438"
/dev/mapper/cryptroot: LABEL="root" UUID="ef02d054-71ed-4235-aee4-ca7f99ef24f8" BLOCK_SIZE="4096" TYPE="ext4"
```

## /etc/crypttab and /etc/fstab

```text
$ cat /etc/crypttab /etc/fstab
cryptroot UUID=b552f692-3938-49ba-99c8-204fbfd004bc none luks,discard,initramfs
UUID=ef02d054-71ed-4235-aee4-ca7f99ef24f8  /          ext4  errors=remount-ro  0 1
UUID=d0bb7d1a-2d2b-4059-9c3b-ef19f40b668c  /boot      ext4  defaults           0 2
UUID=FB2D-2438  /boot/efi  vfat  umask=0077         0 1
```

## Mapping status (cipher, key size)

```text
$ cryptsetup status cryptroot
/dev/mapper/cryptroot is active and is in use.
  type:    LUKS2
  cipher:  aes-xts-plain64
  keysize: 512 [bits]
  key location: keyring
  device:  /dev/sda3
  sector size:  512 [bytes]
  offset:  32768 [512-byte units] (16777216 [bytes])
  size:    38762463 [512-byte units] (19846381056 [bytes])
  mode:    read/write
  flags:   discards 
```

## LUKS header: keyslots and tokens

```text
$ cryptsetup luksDump /dev/sda3
LUKS header information
Version:       	2
Epoch:         	2371
Metadata area: 	16384 [bytes]
Keyslots area: 	16744448 [bytes]
UUID:          	b552f692-3938-49ba-99c8-204fbfd004bc
Label:         	(no label)
Subsystem:     	(no subsystem)
Flags:       	(no flags)

Data segments:
  0: crypt
	offset: 16777216 [bytes]
	length: (whole device)
	cipher: aes-xts-plain64
	sector: 512 [bytes]

Keyslots:
  0: luks2
	Key:        512 bits
	Priority:   normal
	Cipher:     aes-xts-plain64
	Cipher key: 512 bits
	PBKDF:      pbkdf2
	Hash:       sha256
	Iterations: 5866158
	Salt:       ca 12 68 bc b8 68 e4 57 87 1d 65 63 e7 40 f7 ff 
	            ea 82 25 05 32 26 f6 bb 6e 1b 2a 5a 3c e3 89 57 
	AF stripes: 4000
	AF hash:    sha256
	Area offset:32768 [bytes]
	Area length:258048 [bytes]
	Digest ID:  0
  1: luks2
	Key:        512 bits
	Priority:   normal
	Cipher:     aes-xts-plain64
	Cipher key: 512 bits
	PBKDF:      pbkdf2
	Hash:       sha256
	Iterations: 1000
	Salt:       41 53 dc 11 dc d4 f2 df 2d e4 02 fe 12 a5 b4 12 
	            d6 64 50 ca 57 a9 3e 42 1e 3c 3d e0 08 62 cd dc 
	AF stripes: 4000
	AF hash:    sha256
	Area offset:290816 [bytes]
	Area length:258048 [bytes]
	Digest ID:  0
Tokens:
  0: clevis
	Keyslot:    1
Digests:
  0: pbkdf2
	Hash:       sha256
	Iterations: 357631
	Salt:       a7 ba 2e 0d 97 7e 9e dc 66 e4 96 48 db 7a 95 84 
	            6f f7 1d 42 a0 24 bf d0 7a 51 f5 86 f9 c8 d9 e6 
	Digest:     d4 08 05 48 e3 c5 32 22 8f ed 81 f0 95 9d 2f 95 
	            18 76 b7 b5 87 6e 19 5b 6d f7 f6 a1 e9 db 9a 74 
```

## Clevis bindings

```text
$ clevis luks list -d /dev/sda3
1: tpm2 '{"hash":"sha256","key":"ecc","pcr_bank":"sha256","pcr_ids":"7"}'
```

## TPM device nodes

```text
$ ls -l /dev/tpm*
crw-rw---- 1 tss root  10,   224 Oct 20 02:44 /dev/tpm0
crw-rw---- 1 tss tss  252, 65536 Oct 20 02:44 /dev/tpmrm0
```

## PCR values (bank and ids used)

```text
$ tpm2_pcrread sha256:7
  sha256:
    7 : 0x6104AFB36F5D77C24E6FCD4F0481B0C88A268C30FEEE1E3FF5CB2CEB7F80FD12
```

## Secure Boot state

```text
$ mokutil --sb-state
SecureBoot enabled
```

## Enrolled MOK subjects

```text
$ mokutil --list-enrolled | grep -E 'Subject:|SHA1 Fingerprint'
SHA1 Fingerprint: 76:a0:92:06:58:00:bf:37:69:01:c3:72:cd:55:a9:0e:1f:de:d2:e0
        Subject: C=GB, ST=Isle of Man, L=Douglas, O=Canonical Ltd., CN=Canonical Ltd. Master Certificate Authority
SHA1 Fingerprint: c6:56:78:59:91:ee:20:30:f7:9e:d6:42:1f:c1:c2:52:d1:2f:dd:cc
        Subject: CN=Dikshit MOK
```

## Initramfs contains crypto and TPM bits

```text
$ lsinitramfs /boot/initrd.img-7.0.0-38-generic | grep -E 'cryptsetup|clevis|tpm' | head -n 20
scripts/local-bottom/clevis
scripts/local-top/clevis
usr/bin/clevis
usr/bin/clevis-decrypt
usr/bin/clevis-decrypt-null
usr/bin/clevis-decrypt-sss
usr/bin/clevis-decrypt-tang
usr/bin/clevis-decrypt-tpm2
usr/bin/clevis-luks-common-functions
usr/bin/clevis-luks-list
usr/bin/clevis-luks-unlock
usr/bin/tpm2
usr/bin/tpm2_createprimary
usr/bin/tpm2_flushcontext
usr/bin/tpm2_load
usr/bin/tpm2_unseal
usr/lib/cryptsetup
usr/lib/cryptsetup/askpass
usr/lib/cryptsetup/functions
usr/lib/x86_64-linux-gnu/libcryptsetup.so.12
```

## Kernel and OS

```text
$ uname -a; cat /etc/os-release | head -n 4
Linux webclub-os 7.0.0-38-generic #38-Ubuntu SMP PREEMPT_DYNAMIC Fri Sep  4 09:10:14 UTC 2026 x86_64 GNU/Linux
PRETTY_NAME="Ubuntu 26.04 LTS"
NAME="Ubuntu"
VERSION_ID="26.04"
VERSION="26.04 (Resolute Raccoon)"
```

## Proof file

```text
$ cat ~dikshitrj/relic.txt 2>/dev/null || echo '(relic.txt not found at ~dikshitrj)'
Hello,
This file is to show that encryption is successful

the timestamp while writing this file is 20 Oct 07:09:33
```
