#!/usr/bin/env bash
# Builds the app. Defaults to a universal Release build signed with the
# pinned release certificate; pass --dev for a fast local-iteration build
# (single-arch, Debug, ad-hoc signing).
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"

mode=release
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev)
      mode=dev
      ;;
    *)
      echo "Usage: $0 [--dev]" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$mode" == dev ]]; then
  derived_data="${DERIVED_DATA:-$root/.build/dev}"
  app="$root/dist/AudioPriorityBar-dev.app"
  configuration=Debug
  archs=(-arch "$(uname -m)" ONLY_ACTIVE_ARCH=YES)
  sign=skip
else
  derived_data="${DERIVED_DATA:-$root/.build/app}"
  app="$root/dist/AudioPriorityBar.app"
  configuration=Release
  archs=(-arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO)
  sign=pinned
fi

xcodebuild \
  -project "$root/AudioPriorityBar.xcodeproj" \
  -scheme AudioPriorityBar \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data" \
  "${archs[@]}" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$root/dist"
rm -rf "$app"
cp -R \
  "$derived_data/Build/Products/$configuration/AudioPriorityBar.app" \
  "$app"

if [[ "$sign" == pinned ]]; then
  "$root/scripts/sign-app.sh" "$app"
else
  # Local links need an ad-hoc signature to launch; the pinned release
  # certificate is unnecessary for development.
  /usr/bin/codesign --force --sign - "$app"
fi

echo "Build complete: $app"
