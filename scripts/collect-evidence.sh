#!/usr/bin/env bash
# collect-evidence.sh: run INSIDE the booted, encrypted VM.
#
#   sudo ./scripts/collect-evidence.sh [output-dir]      (default: ./evidence)
#
# Produces:
#   evidence/fields.env   values that fill the ${PLACEHOLDERS} in the write-up templates
#   evidence/evidence.md  raw command output, to attach as the appendix
#
# Read-only: it never changes the system. No key material is printed
# (luksDump shows keyslot metadata, not keys).
set -uo pipefail

[ "$EUID" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

OUT="${1:-evidence}"
mkdir -p "$OUT"
FIELDS="$OUT/fields.env"
EVID="$OUT/evidence.md"
: > "$FIELDS"
: > "$EVID"

# ---- helpers ---------------------------------------------------------------
field()   { printf 'export %s=%q\n' "$1" "$2" >> "$FIELDS"; }
blk()     { blkid -s "$2" -o value "$1" 2>/dev/null; }
size()    { lsblk -dno SIZE "$1" 2>/dev/null | tr -d ' '; }
section() {   # section "<title>" "<command>"
  {
    printf '\n## %s\n\n```text\n$ %s\n' "$1" "$2"
    bash -c "$2" 2>&1
    printf '```\n'
  } >> "$EVID"
}

# ---- detect the layout -----------------------------------------------------
ROOT_SRC=$(findmnt -no SOURCE /)                         # e.g. /dev/mapper/cryptroot
MAPPER=$(basename "$ROOT_SRC")
LUKS_DEV=$(cryptsetup status "$MAPPER" 2>/dev/null | awk '/device:/ {print $2; exit}')
if [ -z "$LUKS_DEV" ]; then
  echo "Root ($ROOT_SRC) is not a LUKS mapping. Run this on the encrypted system." >&2
  exit 1
fi

BOOT_DEV=""
mountpoint -q /boot && BOOT_DEV=$(findmnt -no SOURCE /boot)
ESP_DEV=$(findmnt -no SOURCE /boot/efi)
DISK_DEV="/dev/$(lsblk -no PKNAME "$LUKS_DEV" | head -n1)"

# ---- general fields --------------------------------------------------------
field CAPTURE_DATE   "$(date '+%d %b %Y %H:%M:%S %Z')"
field VM_HOSTNAME    "$(hostname)"
field UBUNTU_RELEASE "$(. /etc/os-release && echo "$PRETTY_NAME")"
field KERNEL         "$(uname -r)"
field DISK_DEV       "$DISK_DEV"
field DISK_SIZE      "$(size "$DISK_DEV")"

# ---- partitions ------------------------------------------------------------
part_fields() {   # part_fields <PREFIX> <device>
  field "$1_DEV"      "$2"
  field "$1_SIZE"     "$(size "$2")"
  field "$1_FSTYPE"   "$(blk "$2" TYPE)"
  field "$1_UUID"     "$(blk "$2" UUID)"
  field "$1_PARTUUID" "$(blk "$2" PARTUUID)"
}
part_fields ESP  "$ESP_DEV"
part_fields BOOT "$BOOT_DEV"
part_fields LUKS "$LUKS_DEV"

field ROOT_MAPPER  "$ROOT_SRC"
field ROOT_FS_TYPE "$(blk "$ROOT_SRC" TYPE)"
field ROOT_FS_UUID "$(blk "$ROOT_SRC" UUID)"
field ROOT_SIZE    "$(size "$ROOT_SRC")"

# ---- LUKS parameters -------------------------------------------------------
DUMP=$(cryptsetup luksDump "$LUKS_DEV" 2>&1)
STATUS=$(cryptsetup status "$MAPPER" 2>&1)
field LUKS_VERSION  "$(awk '/^Version:/ {print $2; exit}' <<<"$DUMP")"
field LUKS_CIPHER   "$(awk '/cipher:/ {print $2; exit}' <<<"$STATUS")"
field LUKS_KEYSIZE  "$(awk '/keysize:/ {print $2" "$3; exit}' <<<"$STATUS")"
field LUKS_PBKDF    "$(awk '/PBKDF:/ {print $2}' <<<"$DUMP" | sort -u | paste -sd, -)"
field KEYSLOT_COUNT "$(grep -cE '^[[:space:]]+[0-9]+: luks2' <<<"$DUMP")"

# ---- crypttab / fstab ------------------------------------------------------
field CRYPTTAB_LINE   "$(grep -vE '^[[:space:]]*(#|$)' /etc/crypttab 2>/dev/null | head -n1 | tr -s ' \t' ' ')"
field FSTAB_ROOT_LINE "$(awk '$1 !~ /^#/ && $2=="/" {print; exit}' /etc/fstab | tr -s ' \t' ' ')"

# ---- TPM / Clevis ----------------------------------------------------------
PCR_BANK=""; PCR_IDS=""; CL=""
if command -v clevis >/dev/null 2>&1; then
  CL=$(clevis luks list -d "$LUKS_DEV" 2>&1)
  PCR_BANK=$(grep -o '"pcr_bank":"[^"]*"' <<<"$CL" | head -n1 | cut -d'"' -f4)
  PCR_IDS=$(grep -o '"pcr_ids":"[^"]*"'  <<<"$CL" | head -n1 | cut -d'"' -f4)
fi
field CLEVIS_LIST "$(paste -sd'|' <<<"$CL" | sed 's/|/  |  /g')"
field PCR_BANK    "$PCR_BANK"
field PCR_IDS     "$PCR_IDS"
field PCR_READ    "$(tpm2_pcrread "${PCR_BANK:-sha256}:${PCR_IDS:-7}" 2>/dev/null | paste -sd' ' - | sed 's/  */ /g')"

# ---- Secure Boot -----------------------------------------------------------
field SB_STATE "$(mokutil --sb-state 2>&1 | head -n1)"

# ---- raw evidence appendix -------------------------------------------------
{
  echo "# Evidence: raw command output"
  echo
  echo "Captured $(date '+%d %b %Y %H:%M:%S %Z') on $(hostname)."
} > "$EVID"

section "Partition layout and filesystem UUIDs"  "lsblk -o NAME,SIZE,FSTYPE,UUID,PARTUUID,MOUNTPOINTS $DISK_DEV"
section "blkid"                                  "blkid $ESP_DEV ${BOOT_DEV} $LUKS_DEV $ROOT_SRC"
section "/etc/crypttab and /etc/fstab"           "cat /etc/crypttab /etc/fstab"
section "Mapping status (cipher, key size)"      "cryptsetup status $MAPPER"
section "LUKS header: keyslots and tokens"       "cryptsetup luksDump $LUKS_DEV"
section "Clevis bindings"                        "clevis luks list -d $LUKS_DEV"
section "TPM device nodes"                       "ls -l /dev/tpm*"
section "PCR values (bank and ids used)"         "tpm2_pcrread ${PCR_BANK:-sha256}:${PCR_IDS:-7}"
section "Secure Boot state"                      "mokutil --sb-state"
section "Enrolled MOK subjects"                  "mokutil --list-enrolled | grep -E 'Subject:|SHA1 Fingerprint'"
section "Initramfs contains crypto and TPM bits" "lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'cryptsetup|clevis|tpm' | head -n 20"
section "Kernel and OS"                          "uname -a; cat /etc/os-release | head -n 4"
section "Proof file"                             "cat ~dikshitrj/relic.txt 2>/dev/null || echo '(relic.txt not found at ~dikshitrj)'"

echo
echo "Wrote:"
echo "  $FIELDS"
echo "  $EVID"
echo
echo "Quick look at the key values:"
grep -E '^export (ESP|BOOT|LUKS)_UUID|ROOT_FS_UUID|PCR_BANK|PCR_IDS|SB_STATE|KEYSLOT_COUNT' "$FIELDS"
