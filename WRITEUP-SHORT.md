# LUKS2 + TPM2 Auto-unlock: Short Write-up

**Dikshit RJ** | Mentor: Nischay Bharadwaj Mahesh | Captured `webclub-os`, 20 Oct 2026 04:07:46 UTC

**Result:** Ubuntu installed by hand with `debootstrap`, root converted to LUKS2 in place, and the VM now boots with Secure Boot on (`SecureBoot enabled`) and unlocks itself through the TPM with no prompt. The passphrase keyslot remains as a fallback. Proof: `relic.txt`, written on the encrypted root after an unattended boot (20 Oct 07:09:33).

---

## 1. Partition layout and UUIDs

| # | Device | Size | Type | Mount | UUID |
|---|---|---|---|---|---|
| 1 | `/dev/sda1` | 512M | vfat | `/boot/efi` | `FB2D-2438` |
| 2 | `/dev/sda2` | 1G | ext4 | `/boot` (unencrypted) | `d0bb7d1a-2d2b-4059-9c3b-ef19f40b668c` |
| 3 | `/dev/sda3` | 18.5G | LUKS2 | container | `b552f692-3938-49ba-99c8-204fbfd004bc` |
| 3a | `/dev/mapper/cryptroot` | 18.5G | ext4 | `/` | `ef02d054-71ed-4235-aee4-ca7f99ef24f8` |

`crypttab` uses the **LUKS UUID** (`b552f692-3938-49ba-99c8-204fbfd004bc`); `fstab` and GRUB's `root=` use the **inner ext4 UUID** (`ef02d054-71ed-4235-aee4-ca7f99ef24f8`).

```text
/etc/crypttab   cryptroot UUID=b552f692-3938-49ba-99c8-204fbfd004bc none luks,discard,initramfs
/etc/fstab (/)  UUID=ef02d054-71ed-4235-aee4-ca7f99ef24f8 / ext4 errors=remount-ro 0 1
```

I added a third, unencrypted `/boot` partition. GRUB can't use the TPM, so with `/boot` inside the encrypted root I'd have to type the passphrase every boot. With it outside, the initramfs does the unlocking and Clevis can use the TPM.

## 2. TPM settings

- Bank `sha256`, PCR(s) `7`: PCR 7 is the Secure Boot policy (on/off plus trusted keys).
- Binding: `1: tpm2 '{"hash":"sha256","key":"ecc","pcr_bank":"sha256","pcr_ids":"7"}'`
- I chose PCR 7 because it survives kernel and firmware updates, while PCRs 0/1/4/9 change on routine updates and would lock me out each time.
- Trade-off: PCR 7 doesn't measure the exact kernel or initramfs.
- The passphrase keyslot stays (2 keyslots in total), so a PCR change falls back to a prompt instead of locking the data.

## 3. What went wrong, and the fix

- **Weak passphrase silently aborted the encryption.** `cryptsetup` rejected my passphrase, printed "Operation aborted", and I didn't notice because I ran the commands as one block. Everything after it failed (`not a valid LUKS device`, `/dev/mapper/cryptroot: No such file`), and `crypttab` and initramfs work had nothing to act on. **Fix:** use a long passphrase (4+ random words), run steps one at a time, and verify with `cryptsetup isLuks <dev>` and `luksDump` before continuing. `set -e` in scripts makes the first failure stop the run.
- **Interrupted `reencrypt`** (not hit): never reboot; resume with `cryptsetup reencrypt --resume-only <dev>`. Clone the disk first.
- **Filesystem too full for the header** (not hit): `e2fsck -f`, shrink with `resize2fs`, retry with `--reduce-device-size`.
- **Autounlock stops working after a firmware or Secure Boot change** (expected): unlock with the passphrase, then `clevis luks unbind` and bind again.

Full detail: [WRITEUP.md](WRITEUP.md). Raw outputs: [evidence/evidence.md](evidence/evidence.md).
