#!/usr/bin/env bash
# render-writeup.sh: turn the *.template.md files into final write-ups.
#
#   ./scripts/render-writeup.sh
#
# Run from anywhere (it cd's to the submission root). Needs evidence/fields.env,
# which collect-evidence.sh produces inside the VM (copy the evidence/ folder back with scp).
# Pure bash, no extra packages needed.
set -euo pipefail
cd "$(dirname "$0")/.."

FIELDS=evidence/fields.env
[ -f "$FIELDS" ] || { echo "Missing $FIELDS. Run collect-evidence.sh in the VM first." >&2; exit 1; }

shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: keep '&' in values literal
# shellcheck disable=SC1090
source "$FIELDS"

NAMES=$(grep -o '^export [A-Z_0-9]*' "$FIELDS" | awk '{print $2}')

shopt -s nullglob
RENDERED=()
for T in *.template.md; do
  CONTENT=$(cat "$T")
  for NAME in $NAMES; do
    VALUE=${!NAME-}
    CONTENT=${CONTENT//"\${$NAME}"/$VALUE}
  done
  OUTFILE="${T%.template.md}.md"
  printf '%s\n' "$CONTENT" > "$OUTFILE"
  RENDERED+=("$OUTFILE")
  echo "wrote $OUTFILE"
done

echo
# Only the rendered files are checked, never the templates.
if grep -n '\${[A-Z_0-9]*}' "${RENDERED[@]}"; then
  echo "^ placeholders above had no value in $FIELDS (check collect-evidence.sh output)." >&2
fi
if grep -n '<FILL' "${RENDERED[@]}"; then
  echo "^ fill these in by hand before submitting." >&2
fi
