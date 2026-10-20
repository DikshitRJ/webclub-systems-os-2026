# Manual Full-Disk Encryption: LUKS2 + TPM2 Auto-unlock on Ubuntu

**Author:** Dikshit Rishi Jain

## What I built

I installed Ubuntu by hand with `debootstrap` in a VirtualBox VM (EFI, Secure Boot on, virtual TPM 2.0). I booted it unencrypted first, then encrypted the root partition **in place** to LUKS2 with `cryptsetup reencrypt`, without wiping it. After that I fixed `crypttab`, `fstab`, the initramfs and GRUB so it prompts for a passphrase, enrolled a MOK, and added a TPM2-sealed keyslot with Clevis.

The result: the machine boots from the installed disk with Secure Boot enabled and unlocks itself through the TPM with no prompt. If the boot state changes, it falls back to my passphrase.

## Proof that it works

After an unattended, TPM-unlocked boot, I wrote this file on the encrypted root:

```text
$ cat ~/relic.txt
Hello,
This file is to show that encryption is successful

the timestamp while writing this file is 20 Oct 07:09:33
```

I also tested the fallback. With Secure Boot switched off in VirtualBox, the TPM refused to unseal and I got the passphrase prompt. After I re-enabled it, auto-unlock came back.

## The three things the task asks for

| Deliverable | Where to find it |
|---|---|
| Final partition layout and UUIDs | `WRITEUP.md`, section 3 (and `WRITEUP-SHORT.md`, section 1) |
| Which PCRs I used for auto-unlock | `WRITEUP.md`, section 5 |
| What went wrong, and how I'd fix it | `WRITEUP.md`, section 7, and `ISSUES.md` |

## Files

| File | What it is |
|---|---|
| `WRITEUP.md` | The full write-up, explaining each step and why |
| `WRITEUP-SHORT.md` | A one-page version of the same three answers |
| `ISSUES.md` | Every problem I hit, with symptom, cause and fix, plus failure modes I know how to handle |
| `RUNBOOK.md` | The final procedure in order, with a check after each step |
| `evidence/evidence.md` | Raw command output (`lsblk`, `blkid`, `luksDump`, `clevis luks list`, `tpm2_pcrread`, `mokutil`) captured from the running system |
| `scripts/` | Helper scripts I wrote: guarded encryption, boot fix, TPM binding, and evidence collection. These are optional; the write-up is the deliverable |

## Design decisions worth knowing

- **I added a separate, unencrypted `/boot` partition.** The task lists an ESP and a root partition, but GRUB can't use the TPM. If `/boot` sat inside the encrypted root, I would have to type the passphrase on every boot, which contradicts "no prompt at all". With `/boot` outside, GRUB loads the kernel from plain storage and the initramfs unlocks root, where Clevis can use the TPM.
- **I sealed to PCR 7 (Secure Boot state).** It survives kernel and firmware updates, whereas PCRs that measure the firmware or kernel change on routine updates and would lock me out each time. The trade-off is that PCR 7 doesn't measure the exact kernel or initramfs. I explain this in section 5 of the write-up.
- **I kept the passphrase keyslot.** The TPM can refuse to unseal after a firmware or Secure Boot change, and without the passphrase the data would be unreachable.

## How I worked

I did most of the work from my host over SSH, into the live installer and later into the installed system. I did the in-place encryption and the chroot work from the host by attaching the VDI with `qemu-nbd`. On the host I deliberately skipped `grub-install` and the `efivars` mount, so nothing could touch my own machine's firmware boot entries. Installing, MOK enrollment and TPM binding happened inside the VM, since they need its own firmware and TPM.

## The mistake that cost me the most time

`cryptsetup` rejected my first passphrase as too weak and aborted the encryption. I had run the commands as one pasted block and didn't read the output, so I carried on as if it had worked. Every later step then failed, and the `crypttab` and initramfs work had nothing to act on because the encrypted device never existed. I found the cause by reading the output from the top. The fix was a stronger passphrase, and since then I run each step separately and check `cryptsetup isLuks` before moving on. The full story is in `ISSUES.md`.
