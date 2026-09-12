#!/usr/bin/env bash
set -euo pipefail

build_number="${2:-1}"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${DERIVED_DATA:-$root/build}"
output_dir="${OUTPUT_DIR:-$root/release}"
app="$derived_data/Build/Products/Release/AudioPriorityBar.app"
zip="$output_dir/AudioPriorityBar.zip"

project_versions=$(awk '/MARKETING_VERSION = / {
  gsub(/;/, "", $3); print $3
}' "$root/AudioPriorityBar.xcodeproj/project.pbxproj" | sort -u)

if [[ -z "$project_versions" || "$project_versions" == *$'\n'* ]]; then
  echo "Project configurations do not have one MARKETING_VERSION." >&2
  exit 1
fi
version="${1:-$project_versions}"
if [[ "$version" != "$project_versions" ]]; then
  echo "Requested version $version does not match project version $project_versions." >&2
  exit 1
fi

rm -rf "$derived_data" "$output_dir"
mkdir -p "$output_dir"

xcodebuild \
  -project "$root/AudioPriorityBar.xcodeproj" \
  -scheme AudioPriorityBar \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -arch arm64 -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

while IFS= read -r -d '' file; do
  if /usr/bin/file "$file" | /usr/bin/grep -q "Mach-O"; then
    /usr/bin/codesign --force --sign - "$file"
  fi
done < <(/usr/bin/find "$app/Contents" -type f -print0)
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

actual_version=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
actual_build=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
[[ "$actual_version" == "$version" ]]
[[ "$actual_build" == "$build_number" ]]

architectures=$(/usr/bin/lipo -archs \
  "$app/Contents/MacOS/AudioPriorityBar")
[[ " $architectures " == *" arm64 "* ]]
[[ " $architectures " == *" x86_64 "* ]]
test -s "$app/Contents/Resources/LICENSE"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
(
  cd "$output_dir"
  /usr/bin/shasum -a 256 AudioPriorityBar.zip > AudioPriorityBar.zip.sha256
)

echo "Packaged AudioPriorityBar $version ($build_number)"
echo "Architectures: $architectures"
cat "$output_dir/AudioPriorityBar.zip.sha256"
