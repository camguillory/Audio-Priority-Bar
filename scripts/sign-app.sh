#!/usr/bin/env bash
set -euo pipefail

app="$1"
identity="${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to the SHA-1 fingerprint of your signing certificate.}"
if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "CODESIGN_IDENTITY must be a certificate SHA-1 fingerprint." >&2
  exit 1
fi

while IFS= read -r -d '' file; do
  if /usr/bin/file "$file" | /usr/bin/grep -q "Mach-O"; then
    /usr/bin/codesign --force --sign "$identity" "$file"
  fi
done < <(/usr/bin/find "$app/Contents" -type f -print0)
/usr/bin/codesign --force --sign "$identity" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
