#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
derived_data="${DERIVED_DATA:-$root/.build/app}"
app="$root/dist/AudioPriorityBar.app"

xcodebuild \
  -project "$root/AudioPriorityBar.xcodeproj" \
  -scheme AudioPriorityBar \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -arch arm64 -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$root/dist"
rm -rf "$app"
cp -R \
  "$derived_data/Build/Products/Release/AudioPriorityBar.app" \
  "$root/dist/"

while IFS= read -r -d '' file; do
  if /usr/bin/file "$file" | /usr/bin/grep -q "Mach-O"; then
    /usr/bin/codesign --force --sign - "$file"
  fi
done < <(/usr/bin/find "$app/Contents" -type f -print0)
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

echo "Build complete: $app"
