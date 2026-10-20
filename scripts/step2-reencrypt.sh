#!/usr/bin/env bash
# step2-reencrypt.sh: convert an installed ext4 root partition to LUKS2 in place.
#
#   sudo ./step2-reencrypt.sh /dev/nbd0p3      (or /dev/sda3 from the live ISO)
#
# Why this script exists: my first attempt was a pasted block of commands. cryptsetup
# rejected my weak passphrase, printed "Operation aborted", and every later command failed
# quietly in a cascade. This version stops at the first failure and proves a LUKS header
# exists before it goes on.
#
# Passphrase: use something long (4+ random words). cryptsetup's quality check (libpwquality)
# rejects weak ones. --force-password would bypass the check, but a better passphrase is the fix.
set -euo pipefail

DEV=${1:?usage: $0 <root-partition>}
[ "$EUID" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[ -b "$DEV" ]     || { echo "$DEV is not a block device." >&2; exit 1; }

if grep -q "^$DEV " /proc/mounts; then
  echo "$DEV is mounted. Unmount it first." >&2; exit 1
fi

if cryptsetup isLuks "$DEV" 2>/dev/null; then
  echo "$DEV already has a LUKS header."
  echo "If an earlier run was interrupted, resume it with:"
  echo "    cryptsetup reencrypt --resume-only $DEV"
  exit 0
fi

echo "== 1/5  Check the filesystem"
e2fsck -f "$DEV"

echo "== 2/5  Shrink the filesystem by 64 MiB to leave room for the LUKS2 header"
SIZE_MIB=$(( $(blockdev --getsize64 "$DEV") / 1024 / 1024 ))
resize2fs "$DEV" "$(( SIZE_MIB - 64 ))M"          # prints 'Nothing to do' if already shrunk

echo "== 3/5  Encrypt in place (do NOT interrupt; resume with --resume-only if it happens)"
cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size 32M "$DEV"

echo "== 4/5  Prove the header exists before going any further"
cryptsetup isLuks "$DEV" || {
  echo "FAILED: $DEV has no LUKS header. Read the output above (weak passphrase?)." >&2
  exit 1
}
cryptsetup luksDump "$DEV" | sed -n '1,12p'

echo "== 5/5  Open it and grow the filesystem back to fill the mapping"
cryptsetup open "$DEV" cryptroot
e2fsck -f /dev/mapper/cryptroot
resize2fs /dev/mapper/cryptroot
cryptsetup close cryptroot

echo
echo "Done. Next: step3-fix-boot.sh"
