#!/usr/bin/env bash
set -euo pipefail

build_number="${2:-1}"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${DERIVED_DATA:-$root/build}"
output_dir="${OUTPUT_DIR:-$root/release}"
app="$derived_data/Build/Products/Release/AudioPriorityBar.app"
zip="$output_dir/AudioPriorityBar.zip"
# Sparkle's copy of the archive; Homebrew and manual installs keep the plain zip.
update_zip="$output_dir/AudioPriorityBar-update.zip"
appcast="$output_dir/appcast.xml"
sparkle_bin="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
# Served from the newest non-prerelease, so prereleases never reach the feed.
feed_url="${SPARKLE_FEED_URL:-https://github.com/camguillory/Audio-Priority-Bar/releases/latest/download/appcast.xml}"

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
# Sparkle compares build numbers, so the default of 1 would never be offered.
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" && -z "${2:-}" ]]; then
  echo "Pass the build number when signing an update." >&2
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
  SPARKLE_FEED_URL="$feed_url" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

"$root/scripts/sign-app.sh" "$app"

actual_version=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
actual_build=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
[[ "$actual_version" == "$version" ]]
[[ "$actual_build" == "$build_number" ]]
actual_feed=$(/usr/libexec/PlistBuddy \
  -c "Print :SUFeedURL" "$app/Contents/Info.plist")
[[ "$actual_feed" == "$feed_url" ]]

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

# The appcast is what installed copies poll; without a key there is nothing
# they could verify, so CI's packaging check stops at the zip.
sign() {
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/sign_update" --ed-key-file - "$1"
}
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  cp "$zip" "$update_zip"
  signature=$(sign "$update_zip")
else
  signature=""
  echo "No Sparkle key set; skipping appcast.xml."
fi

if [[ -n "$signature" ]]; then
  download_base="${DOWNLOAD_BASE:-https://github.com/camguillory/Audio-Priority-Bar/releases/download/v$version}"
  # Sparkle picks the delta matching the installed build and falls back to
  # the full archive when none applies.
  deltas=""
  for old_zip in ${PREVIOUS_RELEASES:+"$PREVIOUS_RELEASES"/*.zip}; do
    [[ -f "$old_zip" ]] || continue
    old_dir=$(mktemp -d)
    /usr/bin/ditto -x -k "$old_zip" "$old_dir"
    old_plist="$old_dir/AudioPriorityBar.app/Contents/Info.plist"
    old_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$old_plist")
    old_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$old_plist")
    delta="AudioPriorityBar-from-$old_version.delta"
    "$sparkle_bin/BinaryDelta" create "$old_dir/AudioPriorityBar.app" "$app" "$output_dir/$delta"
    deltas+="
        <enclosure url=\"$download_base/$delta\" sparkle:deltaFrom=\"$old_build\" type=\"application/octet-stream\" $(sign "$output_dir/$delta")/>"
    rm -rf "$old_dir"
  done
  if [[ -n "$deltas" ]]; then
    deltas="<sparkle:deltas>$deltas
      </sparkle:deltas>"
  fi
  minimum_system=$(/usr/libexec/PlistBuddy \
    -c "Print :LSMinimumSystemVersion" "$app/Contents/Info.plist")
  # Shown in the update window; install steps only matter for a first install.
  notes_file="$root/.github/release-notes/v$version.md"
  notes=""
  if [[ -f "$notes_file" ]]; then
    notes="<description sparkle:format=\"markdown\"><![CDATA[$(sed '/^## Install/,$d' "$notes_file")]]></description>"
  fi
  cat > "$appcast" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Audio Priority Bar</title>
    <item>
      <title>Version $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum_system</sparkle:minimumSystemVersion>
      $notes
      <enclosure url="$download_base/AudioPriorityBar-update.zip" type="application/octet-stream" $signature/>
      $deltas
    </item>
  </channel>
</rss>
XML
  /usr/bin/xmllint --noout "$appcast"
fi

echo "Packaged AudioPriorityBar $version ($build_number)"
echo "Architectures: $architectures"
cat "$output_dir/AudioPriorityBar.zip.sha256"
