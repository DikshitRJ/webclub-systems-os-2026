# Issue Log: LUKS2 + TPM2 Auto-unlock

Every problem I hit (and a few I know how to fix but didn't hit), in the format: symptom, cause, fix, how to catch it earlier.

---

## Issues I actually hit

### 1. Weak passphrase aborted the in-place encryption (the one I missed)

**Symptom.** After `cryptsetup reencrypt --encrypt` and my confirmation, the output ended with:

```text
Operation aborted.
Device /dev/nbd0p3 is not a valid LUKS device.
e2fsck: No such file or directory while trying to open /dev/mapper/cryptroot
Device cryptroot is not active.
```

**Why I missed it.** I had pasted the whole sequence (shrink, reencrypt, open, fsck, grow, close) as one block. Each later command failed, but the failures looked like separate, unrelated errors. Later, in Step 3, the `crypttab` and initramfs work had nothing to act on because there was no `cryptroot` device to open or mount, and I didn't connect that to the first failure.

**Root cause.** `cryptsetup` checks new passphrases against a quality policy and rejected mine as too weak. No LUKS header was ever written, so the partition was still plain ext4.

**Fix.** Choose a long passphrase, such as four or more random words. `--force-password` skips the quality check, but a stronger passphrase is the better fix, since this passphrase is also the permanent fallback if the TPM fails.

**Catch it earlier next time.**

```bash
sudo cryptsetup isLuks /dev/<root-part> && echo "LUKS header present"
sudo cryptsetup luksDump /dev/<root-part> | head
```

Run steps one at a time and read the output. In scripts use `set -euo pipefail` so the first failure stops everything. `scripts/step2-reencrypt.sh` does this and refuses to continue unless a header exists.

---

### 2. The VDI wasn't in the VM folder

**Symptom.** `tree "VirtualBox VMs"` showed only the `.vbox`, `.nvram` and logs, with no `.vdi`.

**Cause.** The disk had been created at a different path than the VM folder. VirtualBox lets you choose the location in the wizard.

**Fix.** Ask VirtualBox where the VM's disk is:

```bash
VBoxManage list hdds
grep -i "location=" ~/"VirtualBox VMs"/<vm>/<vm>.vbox
```

If the path is wrong or empty, `find ~ -name "*.vdi"` locates it. If there's no disk attached at all, create one under Settings, Storage and start again.

---

### 3. `resize2fs`: "already 4832768 (4k) blocks long. Nothing to do!"

**Symptom.** On the retry, the shrink step printed that message.

**Cause.** The filesystem was already at the target size, so there was nothing left to shrink. It is harmless and idempotent.

**Fix.** None needed. It does confirm the filesystem was shrunk and the header space was reserved.

---

### 4. The two-partition layout conflicts with "no prompt at all" (design issue)

**Symptom (predicted before building).** The task asks for an ESP plus a root partition, and for auto-unlock with no prompt.

**Cause.** With `/boot` inside the encrypted root, GRUB must unlock the disk itself to read the kernel. GRUB can't use Clevis or the TPM, so it would prompt for a passphrase on every boot.

**Fix.** A third, small, unencrypted `/boot` partition. GRUB reads the kernel from there, and the initramfs unlocks root, where Clevis works. Raised as a deviation in the write-up.

---

## Failure modes I understand but did not hit

### 5. `reencrypt` interrupted

**Symptom.** Power loss, host sleep or a killed VM mid-run. The partition is half plaintext and half ciphertext.

**Fix.** Don't reboot and don't start over. Resume:

```bash
sudo cryptsetup reencrypt --resume-only /dev/<root-part>
```

**Prevention.** Clone the VDI first, disable host sleep, don't close the VM.

### 6. Filesystem too full for the LUKS2 header

**Symptom.** `reencrypt` refuses, or reports there isn't enough space.

**Fix.** `e2fsck -f`, then shrink the filesystem with `resize2fs` by more than the header needs, then retry with `--reduce-device-size`.

### 7. Boots into a UEFI shell

**Cause.** VirtualBox lost the NVRAM boot entry.

**Fix.** Boot a live ISO, chroot into the VM's own disk, and run `grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --uefi-secure-boot`. (The `efivars` bind mount is only safe inside the VM, never on the host.)

### 8. Passphrase prompt still appears after the TPM setup

**Causes.** The initramfs lacks the Clevis hook, or the TPM driver modules aren't in the initramfs.

**Fix.**

```bash
lsinitramfs /boot/initrd.img-$(uname -r) | grep -Ei 'clevis|tpm'
# if the tpm modules are missing:
echo -e "tpm_tis\ntpm_crb" | sudo tee -a /etc/initramfs-tools/modules
sudo update-initramfs -u -k all
```

Also check that PCR 7 isn't all zeros (`tpm2_pcrread sha256:7`), which means measured Secure Boot isn't active in the VM.

### 9. TPM refuses to unseal after a firmware or Secure Boot change

**Cause.** The sealed PCR value changed. This is expected, and it is why the passphrase keyslot is kept.

**Fix.** Unlock with the passphrase, then replace the binding:

```bash
sudo clevis luks list -d /dev/<root-part>
sudo clevis luks unbind -d /dev/<root-part> -s <slot>
sudo clevis luks bind   -d /dev/<root-part> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
sudo update-initramfs -u -k all
```

### 10. Working on the wrong disk image

**Cause.** If the VM has snapshots, the base VDI is not the VM's current state. Writing to it corrupts the snapshot chain.

**Fix.** Clone the current state to a standalone VDI with `VBoxManage clonemedium disk`, and work on the clone.

### 11. Damaged LUKS header

**Fix.** Restore from a header backup, taken once everything works: `cryptsetup luksHeaderBackup <dev> --header-backup-file luks-header.img`. Store it outside the VM, and don't commit it to the repo.
