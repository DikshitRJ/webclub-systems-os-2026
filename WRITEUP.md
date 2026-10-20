# Manual Full-Disk Encryption: LUKS2 + TPM2 Auto-unlock on Ubuntu (VirtualBox)

**Author:** Dikshit RJ
**Mentor:** Nischay Bharadwaj Mahesh
**System captured:** `webclub-os`, 20 Oct 2026 04:07:46 UTC

---

## 1. Summary

I installed Ubuntu by hand with `debootstrap` onto an unencrypted disk and confirmed it booted. Then I converted the root partition to LUKS2 **in place** with `cryptsetup reencrypt`, fixed `crypttab`, `fstab`, the initramfs and GRUB so it asks for a passphrase, and finally sealed a second key to the VM's TPM 2.0 with Clevis so it unlocks with no prompt. The passphrase keyslot is still there as a fallback.

Final state:

| Check | Result |
|---|---|
| Secure Boot | `SecureBoot enabled` |
| Root filesystem | LUKS2 on `/dev/sda3`, opened as `/dev/mapper/cryptroot` |
| Normal boot | Unlocks with no prompt via TPM2 |
| TPM seal | PCR(s) `7`, `sha256` bank |
| Fallback | Passphrase keyslot kept (2 keyslots in total) |

**Proof that the encrypted system works.** Before the encryption, I created this file in the root of the home directory. It is still accessible after the encryption and unattended TPM-unlocked boot:

```text
$ cat ~/relic.txt
Hello,
This file is to show that encryption is successful

the timestamp while writing this file is 20 Oct 07:09:33
```

---

## 2. Environment and workflow

| Item | Value |
|---|---|
| Hypervisor | VirtualBox 7.2.20_SUSEr175154 |
| Host OS | OpenSUSE Tumbleweed (Linux 7.2.11-1-default) |
| VM resources | 2gb RAM, 1 vCPU |
| Firmware | EFI with Secure Boot enabled, virtual TPM 2.0 |
| Guest | Ubuntu 26.04 LTS, kernel `7.0.0-38-generic` |
| Disk | `/dev/sda`, 20G (VDI) |

I worked mostly from my host rather than the VirtualBox console. I SSHed into the live installer session and, later, into the installed system. I did the in-place encryption and the chroot work from the host by attaching the VDI as a block device with `qemu-nbd`. Installing the system, enrolling the MOK and binding the TPM happened inside the VM, because those need the VM's own firmware and TPM state.

---

## 3. Final partition layout and UUIDs

```text
/dev/sda  (20G, GPT)
├─ 1  ESP              512M   vfat        /boot/efi   unencrypted
├─ 2  /boot            1G   ext4       /boot       unencrypted
└─ 3  LUKS2 container  18.5G   crypto_LUKS
      └─ /dev/mapper/cryptroot   18.5G   ext4   /           encrypted
```

| # | Device | Size | Type | Mount | UUID | PARTUUID |
|---|---|---|---|---|---|---|
| 1 | `/dev/sda1` | 512M | vfat | `/boot/efi` | `FB2D-2438` | `a99b1c5a-d96c-449e-b634-8bb930d00e38` |
| 2 | `/dev/sda2` | 1G | ext4 | `/boot` | `d0bb7d1a-2d2b-4059-9c3b-ef19f40b668c` | `d877bab7-4d29-4b1e-a8f9-dfc672697364` |
| 3 | `/dev/sda3` | 18.5G | crypto_LUKS | LUKS2 container | `b552f692-3938-49ba-99c8-204fbfd004bc` | `19475771-7cf6-42da-9104-ef510b83a438` |
| 3a | `/dev/mapper/cryptroot` | 18.5G | ext4 | `/` | `ef02d054-71ed-4235-aee4-ca7f99ef24f8` | n/a |

There are **two different UUIDs for the root**, and mixing them up is an easy mistake:

- `b552f692-3938-49ba-99c8-204fbfd004bc` identifies the LUKS container (the partition). `/etc/crypttab` uses this one, because the initramfs needs it *before* anything is unlocked.
- `ef02d054-71ed-4235-aee4-ca7f99ef24f8` identifies the ext4 filesystem inside the container. It is the same UUID the filesystem had before encryption, because `reencrypt` keeps the data intact. `fstab` and GRUB's `root=` use it.

Configuration as it ended up:

```text
/etc/crypttab   cryptroot UUID=b552f692-3938-49ba-99c8-204fbfd004bc none luks,discard,initramfs
/etc/fstab (/)  UUID=ef02d054-71ed-4235-aee4-ca7f99ef24f8 / ext4 errors=remount-ro 0 1
```

LUKS parameters: LUKS2, cipher `aes-xts-plain64`, key size 512 [bits], PBKDF(s) in use: `pbkdf2`.

### Why a separate unencrypted `/boot`

The task text lists two partitions (ESP and root). I added a third small `/boot`. If `/boot` lived inside the encrypted root, GRUB would have to unlock the disk itself to read the kernel. GRUB can't talk to the TPM, so I'd have to type the passphrase on every boot, which contradicts "no prompt at all". With a separate `/boot`, GRUB loads the kernel from plain storage and the initramfs does the unlocking, where Clevis can use the TPM. The kernel and initramfs are not secret, and Secure Boot protects the bootloader and kernel signature chain.

---

## 4. What I did, step by step, and why

### Step 1: Partition and install
I created the ESP, `/boot` and root partitions with `sgdisk`, made the filesystems, and ran `debootstrap` onto the root. Then I added the kernel, GRUB (signed `shim` and `grub-efi-amd64-signed` packages so Secure Boot accepts them), `cryptsetup` and its initramfs hooks, hostname, user and network config. I ran `grub-install --uefi-secure-boot`, rebooted from disk and confirmed it booted **unencrypted** with Secure Boot on. I installed `cryptsetup-initramfs` this early so the later initramfs rebuild could include the unlock code.

### Step 2: Encrypt root in place
`cryptsetup reencrypt --encrypt` converts a live filesystem to LUKS2 without wiping it. A LUKS2 header needs space at the start of the partition, and a full partition has none. So I:

1. ran `e2fsck -f` to make sure the filesystem was clean,
2. shrank it with `resize2fs` by 64 MiB,
3. ran `cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size 32M`, which shifts the data forward to make room for the header,
4. opened the result, ran `e2fsck` again, and grew the filesystem back with `resize2fs` so it fills the mapping.

This is the riskiest step because it rewrites every block in place. If it is interrupted, the partition is half plaintext and half ciphertext. The recovery is `cryptsetup reencrypt --resume-only <device>`, not a reboot or a re-run. A disk clone before starting is the real safety net.

### Step 3: Fix the boot process
An encrypted root won't boot unless the initramfs knows to unlock it first. I opened the container, mounted it with `/boot` and the ESP, bind-mounted `/dev`, `/proc` and `/sys`, and chrooted in. Then I:

- wrote `/etc/crypttab` with the **LUKS UUID** (see section 3) and the `initramfs` option so unlocking happens early,
- checked that `fstab` pointed at the right filesystem,
- ran `update-initramfs -u -k all`, which bakes the `cryptsetup` unlock code into the initramfs,
- ran `update-grub` to regenerate the config.

I did **not** run `grub-install` from the host, and I did not bind-mount `efivars` there. That would have written boot entries into my real machine's firmware. GRUB was already on the unencrypted ESP, so it wasn't needed. On the next boot, the passphrase prompt appeared and the system came up.

### Step 4: MOK enrollment
I generated an RSA key pair with `openssl`, queued the public certificate with `mokutil --import`, rebooted, and confirmed in the blue MOK Manager screen (Enroll MOK, Continue, Yes, one-time password). Nothing in this setup needs the key yet, since I'm not loading unsigned modules. I did it before the TPM step so the measured boot state was stable when I sealed. The private key stays out of the repo.

### Step 5: TPM2 auto-unlock
I installed `clevis`, `clevis-tpm2`, `clevis-luks`, `clevis-initramfs` and `tpm2-tools`, checked that `/dev/tpmrm0` exists, and bound the container to the TPM:

```bash
sudo clevis luks bind -d /dev/sda3 tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
sudo update-initramfs -u -k all
```

Clevis adds a **second keyslot** whose key is sealed inside the TPM. The passphrase keyslot is untouched. The rebuilt initramfs includes the Clevis hook, which asks the TPM to unseal the key at boot. After a reboot the machine came up without prompting.

---

## 5. TPM settings (PCRs)

| Setting | Value |
|---|---|
| PCR bank | `sha256` |
| PCR IDs | `7` |
| Value when sealed | ` sha256: 7 : 0x6104AFB36F5D77C24E6FCD4F0481B0C88A268C30FEEE1E3FF5CB2CEB7F80FD12` |
| Clevis binding | `1: tpm2 '{"hash":"sha256","key":"ecc","pcr_bank":"sha256","pcr_ids":"7"}'` |

**Why PCR 7.** PCR 7 records the Secure Boot policy: whether Secure Boot is on and which keys and signature databases are trusted. Sealing to it means the TPM only releases the key if Secure Boot is still enabled with the same trust configuration. Turning Secure Boot off, or changing the enrolled keys, changes PCR 7 and the unseal fails.

**Why not more PCRs.** Binding to PCRs that hash the firmware (0, 1) or the bootloader and kernel (4, 9 and so on) is stricter, but those values change on routine events such as firmware updates and kernel upgrades. Each of those would lock me out of auto-unlock until I re-bound. PCR 7 survives kernel updates, which is the trade I wanted for a machine I use daily.

**The trade-off I'm aware of.** PCR 7 does not measure the exact kernel or initramfs. With an unencrypted `/boot`, someone with disk access could in principle swap the initramfs, and Secure Boot only partly covers that. A tighter setup would use a signed unified kernel image with signed PCR policies, which is beyond this task.

**Why the passphrase stays.** A BIOS or firmware change, a Secure Boot key update or a TPM reset makes the unseal fail. Without a second keyslot the data would be unreachable. With it, the boot falls back to the passphrase prompt.

---

## 6. Verification

- Secure Boot: `mokutil --sb-state` gives `SecureBoot enabled`.
- TPM unlock: the machine boots from the encrypted disk with no prompt, and `relic.txt` (section 1) was written on the encrypted root afterwards.
- Keyslots: `cryptsetup luksDump /dev/sda3` shows 2 keyslots (passphrase plus Clevis) and a `clevis` token.
- Initramfs: `lsinitramfs` shows the cryptsetup and Clevis/TPM pieces (see the appendix).

### Fallback test (passphrase prompt when the boot state changes)

To test the fallback, I powered the VM off and disabled Secure Boot in VirtualBox (Settings → System → Motherboard). On the next boot the TPM refused to unseal the key, because PCR 7 no longer matched the sealed value, and the system showed the normal "Please unlock disk cryptroot" passphrase prompt instead of failing. I entered my passphrase and it booted normally. I then powered off, re-enabled Secure Boot, and booted again, and the disk unlocked automatically with no prompt, since PCR 7 was back to its sealed value. 

---

## 7. What went wrong, and how I'd fix it

### The big one: the passphrase was rejected and I didn't notice

When I ran `cryptsetup reencrypt --encrypt`, `cryptsetup` refused my passphrase because it was too weak, and the run aborted. I ran the commands as one pasted block and didn't read the output, so I carried on as if encryption had happened. Nothing was encrypted, so everything after it failed, but the errors only looked like separate problems:

```text
Operation aborted.
Device /dev/nbd0p3 is not a valid LUKS device.
e2fsck: No such file or directory while trying to open /dev/mapper/cryptroot
Device cryptroot is not active.
```

That is also why the `crypttab` and initramfs work from Step 3 had nothing to act on: there was no `cryptroot` device to open or mount. I only found the cause when I went back through the output from the start.

**Fix:** use a stronger passphrase with letters, numbers and special characters. `--force-password` bypasses the quality check, but a stronger passphrase is the real fix because it is also the permanent fallback for the TPM.

**What I changed in my process:**

1. Run the steps one at a time and read each result.
2. After `reencrypt`, always check that a header exists before moving on: `cryptsetup isLuks <device> && echo OK`, then look at `cryptsetup luksDump <device>`.
3. Use `set -e` in scripts so the first failure stops everything (`scripts/step2-reencrypt.sh` does this and verifies the header itself).

### Smaller issues

| Problem | Cause | Fix |
|---|---|---|
| Couldn't find the VDI in the VM folder | The disk was stored elsewhere | Find it from the VM config: `VBoxManage list hdds`, or the `location=` entries in the `.vbox` file |
| `resize2fs` said "already N blocks long. Nothing to do!" on the retry | The filesystem was already at the target size from the earlier attempt | Harmless; the shrink is idempotent |
| Two-partition layout conflicts with "no prompt" | GRUB can't use the TPM | Added a separate unencrypted `/boot` (section 3) |

### Failure modes I understand but did not hit

| Failure | What I'd do |
|---|---|
| `reencrypt` interrupted (power loss, killed VM) | Don't reboot. `cryptsetup reencrypt --resume-only <device>` |
| Filesystem doesn't fit with the header | `e2fsck -f`, then shrink further with `resize2fs` and retry |
| Boots to a UEFI shell | NVRAM entry lost. From a chroot on the VM's own disk: `grub-install --removable --uefi-secure-boot` |
| Passphrase prompt appears again after TPM setup | The initramfs lacks the TPM modules or the Clevis hook: check `lsinitramfs`, add `tpm_tis` and `tpm_crb` to `/etc/initramfs-tools/modules`, rebuild |
| PCR changed after a firmware or Secure Boot change | Passphrase unlock, then `clevis luks unbind -d <dev> -s <slot>` and bind again |
| Editing the wrong disk image when VM snapshots exist | The base VDI isn't the current state; clone the current state to a standalone VDI first |
| Damaged LUKS header | `cryptsetup luksHeaderBackup` once everything works, stored **outside** the VM and the repo |

---

## 8. Deviations from the task text

1. **Separate `/boot` partition** (three partitions instead of two), explained in section 3.
2. **Steps 2 and 3 done from my host** with `qemu-nbd` instead of the live ISO. The `cryptsetup` and `chroot` operations are the same either way. I skipped `grub-install` and the `efivars` mount on the host so it couldn't affect my real machine's firmware.

---

## Appendix

Raw command output (`lsblk`, `blkid`, `luksDump`, `clevis luks list`, `tpm2_pcrread`, `mokutil`) is in [`evidence/evidence.md`](evidence/evidence.md).
