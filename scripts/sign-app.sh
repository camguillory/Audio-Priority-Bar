#!/usr/bin/env bash
set -euo pipefail

app="$1"
# SHA-1 of the self-made "Audio Priority Bar Signing" certificate. macOS ties
# privacy permissions to it, so every release must carry this exact one.
certificate="f1fe88735a77d5ad96a9e285e04046cf36a503f0"

identity="-"
if /usr/bin/security find-identity -p codesigning \
  | /usr/bin/grep -qi "$certificate"; then
  identity="$certificate"
elif [[ -n "${REQUIRE_SIGNING_CERTIFICATE:-}" ]]; then
  echo "Signing certificate $certificate is not in any keychain." >&2
  exit 1
else
  echo "Signing certificate not found; signing ad-hoc." >&2
fi

while IFS= read -r -d '' file; do
  if /usr/bin/file "$file" | /usr/bin/grep -q "Mach-O"; then
    /usr/bin/codesign --force --sign "$identity" "$file"
  fi
done < <(/usr/bin/find "$app/Contents" -type f -print0)
/usr/bin/codesign --force --sign "$identity" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

if [[ "$identity" != "-" ]] && ! /usr/bin/codesign -d -r- "$app" 2>&1 \
  | /usr/bin/grep -qi "H\"$certificate\""; then
  echo "Designated requirement does not pin the signing certificate." >&2
  exit 1
fi
