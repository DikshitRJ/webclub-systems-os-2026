# Runbook: the final, working procedure

The order I'd follow if I did it again, with a check after each step. Device names assume the guest disk is `/dev/sda` inside the VM and `/dev/nbd0` when attached on the host. Adjust to your system.

Layout: `sda1` ESP 512 MiB (FAT32), `sda2` `/boot` 1 GiB (ext4), `sda3` root (ext4, later LUKS2).

---

## 0. VM and workflow setup

VirtualBox, new VM (Linux, Ubuntu 64-bit), 4 GB RAM, 2 CPUs, 25 GB VDI. Before first boot, under Settings, System, Motherboard:

- Enable EFI
- Enable Secure Boot (use "Reset Keys to Default" if offered)
- TPM: v2.0

Network is NAT with a port-forward rule (host `2222` to guest `22`) so I can SSH in from the host. In the live session, make sure SSH is running and a password is set, then:

```bash
ssh -p 2222 <user>@127.0.0.1
sudo -i
ls /sys/firmware/efi && mokutil --sb-state      # UEFI mode, SecureBoot enabled
```

## 1. Partition and install (inside the live session)

```bash
apt update && apt install -y debootstrap gdisk cryptsetup
sgdisk --zap-all /dev/sda
sgdisk -n1:0:+512M -t1:ef00 -c1:ESP  /dev/sda
sgdisk -n2:0:+1G   -t2:8300 -c2:boot /dev/sda
sgdisk -n3:0:0     -t3:8304 -c3:root /dev/sda
mkfs.vfat -F32 /dev/sda1
mkfs.ext4 -L boot /dev/sda2
mkfs.ext4 -L root /dev/sda3

mount /dev/sda3 /mnt
REL=$(lsb_release -cs)
debootstrap --arch amd64 "$REL" /mnt http://in.archive.ubuntu.com/ubuntu
mkdir -p /mnt/boot && mount /dev/sda2 /mnt/boot
mkdir -p /mnt/boot/efi && mount /dev/sda1 /mnt/boot/efi
for d in dev dev/pts proc sys sys/firmware/efi/efivars; do mount --bind /$d /mnt/$d; done
cp /etc/resolv.conf /mnt/etc/resolv.conf
```

Write `hostname`, `sources.list`, `fstab` (by UUID, three entries) and a netplan file, then chroot:

```bash
chroot /mnt /bin/bash
apt update
apt install -y linux-image-generic grub-efi-amd64 grub-efi-amd64-signed shim-signed \
  cryptsetup cryptsetup-initramfs initramfs-tools sudo nano locales netplan.io \
  systemd-resolved openssh-server
adduser <user> && usermod -aG sudo <user>
passwd root
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --uefi-secure-boot
update-grub
exit
umount -R /mnt && poweroff
```

**Check:** remove the ISO, boot from disk. It must boot **unencrypted**, and `mokutil --sb-state` must say `SecureBoot enabled`.

## 2. Encrypt root in place

Clone the VDI first (power the VM off). If the VM has snapshots, clone the *current state*, not the base disk:

```bash
VBoxManage clonemedium disk "<current>.vdi" backup.vdi --format VDI
```

Then either boot the live ISO and use `/dev/sda3`, or (what I did) attach the VDI on the host:

```bash
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 -f vdi /path/to/vm.vdi
lsblk /dev/nbd0                                  # nbd0p1, nbd0p2, nbd0p3

sudo ./scripts/step2-reencrypt.sh /dev/nbd0p3
```

Pick a **long passphrase** (four or more random words). A weak one is rejected and the run aborts, which is the mistake I made once.

**Check (before going on):**

```bash
sudo cryptsetup isLuks /dev/nbd0p3 && echo OK
sudo cryptsetup luksDump /dev/nbd0p3 | head
```

## 3. Fix the boot process

Still with the disk attached on the host:

```bash
sudo ./scripts/step3-fix-boot.sh /dev/nbd0p3 /dev/nbd0p2 /dev/nbd0p1
sudo qemu-nbd --disconnect /dev/nbd0
```

(The script opens the container, writes `/etc/crypttab`, rebuilds the initramfs, runs `update-grub`, then cleans up. It never runs `grub-install` or mounts `efivars` on the host.)

**Check:** boot the VM. It must show "Please unlock disk cryptroot", and after the passphrase, Ubuntu must boot.

## 4. MOK enrollment (inside the VM)

```bash
sudo apt install -y mokutil openssl
mkdir ~/mok && cd ~/mok
openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout MOK.priv -outform DER -out MOK.der -subj "/CN=<name> MOK/"
sudo mokutil --import MOK.der          # sets a one-time password
sudo reboot
```

At the blue screen: press a key, Enroll MOK, Continue, Yes, enter the one-time password, Reboot.

**Check:** `mokutil --list-enrolled | grep Subject`. Keep `MOK.priv` out of the repo.

## 5. TPM2 auto-unlock (inside the VM)

```bash
sudo ./scripts/step5-tpm-bind.sh /dev/sda3 7
sudo reboot
```

**Check:** it must boot with **no prompt**. `sudo clevis luks list -d /dev/sda3` should list a `tpm2` binding, and `luksDump` should show two keyslots.

## 6. Fallback test

1. Power the VM off.
2. In VirtualBox, Settings, System, Motherboard, untick **Enable Secure Boot**.
3. Boot. PCR 7 changes, the TPM refuses to unseal, and you get the passphrase prompt. Enter it; it must boot.
4. Power off, re-enable Secure Boot, boot again. Auto-unlock should return.

## 7. Collect evidence and render the write-up

```bash
# in the VM
sudo ./scripts/collect-evidence.sh
# on the host, copy back (adjust the port/user)
scp -P 2222 -r <user>@127.0.0.1:~/luks-tpm2-submission/evidence ./
./scripts/render-writeup.sh
```

Also take a header backup, stored **outside** the repo:

```bash
sudo cryptsetup luksHeaderBackup /dev/sda3 --header-backup-file ~/luks-header.img
```
