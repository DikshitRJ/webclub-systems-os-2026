#!/usr/bin/env bash
# step3-fix-boot.sh: make the encrypted root bootable (crypttab, initramfs, GRUB config).
#
#   sudo ./step3-fix-boot.sh <root-part> <boot-part> <esp-part>
#   e.g. sudo ./step3-fix-boot.sh /dev/nbd0p3 /dev/nbd0p2 /dev/nbd0p1
#
# Works from the host (VDI attached with qemu-nbd) or from the live ISO.
# It deliberately does NOT bind-mount efivars and does NOT run grub-install, so it can never
# touch the UEFI boot entries of the machine it runs on. GRUB already sits on the unencrypted
# ESP and /boot, and Step 2 never touched them.
set -euo pipefail

ROOT=${1:?usage: $0 <root-part> <boot-part> <esp-part>}
BOOT=${2:?usage: $0 <root-part> <boot-part> <esp-part>}
ESP=${3:?usage: $0 <root-part> <boot-part> <esp-part>}
[ "$EUID" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

cryptsetup isLuks "$ROOT" || {
  echo "ERROR: $ROOT has no LUKS header. Step 2 did not finish; re-check its output (weak passphrase?)." >&2
  exit 1
}

MNT=/mnt
cleanup() {
  set +e
  umount -R "$MNT" 2>/dev/null
  cryptsetup close cryptroot 2>/dev/null
}
trap cleanup EXIT

cryptsetup open "$ROOT" cryptroot
mount /dev/mapper/cryptroot "$MNT"
mount "$BOOT" "$MNT/boot"
mount "$ESP"  "$MNT/boot/efi"
for d in dev dev/pts proc sys; do mount --bind "/$d" "$MNT/$d"; done

# crypttab uses the UUID of the LUKS container (the partition), not the ext4 UUID inside it.
LUKS_UUID=$(blkid -s UUID -o value "$ROOT")
echo "cryptroot UUID=$LUKS_UUID none luks,discard,initramfs" > "$MNT/etc/crypttab"

echo "--- /etc/crypttab"; cat "$MNT/etc/crypttab"
echo "--- /etc/fstab";    cat "$MNT/etc/fstab"

chroot "$MNT" /bin/bash -c 'update-initramfs -u -k all && update-grub'

echo "--- initramfs should now contain cryptsetup:"
chroot "$MNT" /bin/bash -c 'lsinitramfs "$(ls -1v /boot/initrd.img-* | tail -n1)" | grep -E "cryptsetup|crypttab" | head -n 5'

echo
echo "Done. Detach the disk and boot the VM; it should now ask for the passphrase."
