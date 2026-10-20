#!/usr/bin/env bash
# step5-tpm-bind.sh: add a TPM2-sealed keyslot next to the passphrase (run INSIDE the booted VM).
#
#   sudo ./step5-tpm-bind.sh /dev/sda3 [PCR-ids]      (default PCR 7 = Secure Boot state)
#
# The passphrase keyslot is NOT removed. It is the fallback when the TPM refuses to unseal.
# clevis will ask for your existing LUKS passphrase once.
set -euo pipefail

DEV=${1:?usage: $0 <luks-partition> [pcr-ids]}
PCRS=${2:-7}
[ "$EUID" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
cryptsetup isLuks "$DEV" || { echo "$DEV is not a LUKS device." >&2; exit 1; }

apt-get install -y clevis clevis-tpm2 clevis-luks clevis-initramfs tpm2-tools

[ -e /dev/tpmrm0 ] || {
  echo "No /dev/tpmrm0. Enable TPM 2.0 in the VM settings (System > Motherboard) and reboot." >&2
  exit 1
}

echo "--- PCR values that will be sealed against:"
tpm2_pcrread "sha256:$PCRS"

# PCR 7 reads as all zeros when the firmware is not doing measured Secure Boot.
if tpm2_pcrread "sha256:$PCRS" | grep -Eq '0x0{64}'; then
  echo "WARNING: a selected PCR is all zeros. Is Secure Boot enabled in the VM settings?" >&2
fi

clevis luks bind -d "$DEV" tpm2 "{\"pcr_bank\":\"sha256\",\"pcr_ids\":\"$PCRS\"}"

echo "--- bindings:"
clevis luks list -d "$DEV"

update-initramfs -u -k all

echo
echo "Done. Reboot: it should unlock with no prompt."
echo "Then run the fallback test (README.md, 'Before you submit')."
