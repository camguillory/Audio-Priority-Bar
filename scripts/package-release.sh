#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --unsigned ]]; then
  shift
  unset CODESIGN_IDENTITY SPARKLE_PUBLIC_KEY SPARKLE_PRIVATE_KEY SPARKLE_FEED_URL DOWNLOAD_BASE
fi
build_number="${2:-1}"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${DERIVED_DATA:-$root/build}"
output_dir="${OUTPUT_DIR:-$root/release}"
sparkle_bin="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
feed_url="${SPARKLE_FEED_URL:-}"
public_key="${SPARKLE_PUBLIC_KEY:-}"
download_base="${DOWNLOAD_BASE:-}"

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
# Update-enabled releases require the maintainer's own feed and signing keys.
if [[ -n "$feed_url$public_key$download_base${SPARKLE_PRIVATE_KEY:-}" ]]; then
  if [[ "$feed_url" != https://* || "$download_base" != https://* || -z "$public_key" ||
        -z "${SPARKLE_PRIVATE_KEY:-}" || -z "${CODESIGN_IDENTITY:-}" || -z "${2:-}" ]]; then
    echo "Updates require HTTPS SPARKLE_FEED_URL and DOWNLOAD_BASE, SPARKLE_PUBLIC_KEY, SPARKLE_PRIVATE_KEY, CODESIGN_IDENTITY and a build number." >&2
    exit 1
  fi
fi

# Keep existing build caches and unrelated exports. Publish only artifacts
# produced by this run after packaging and validation succeed.
mkdir -p "$output_dir"
staging=$(mktemp -d "$output_dir/.audio-priority-release.XXXXXXXX")
trap 'rm -rf "$staging"' EXIT
zip="$staging/AudioPriorityBar.zip"
update_zip="$staging/AudioPriorityBar-update.zip"
appcast="$staging/appcast.xml"
app_appcast="$staging/appcast-app.xml"
mkdir "$staging/.products"
products="$(cd "$staging/.products" && pwd)"
app="$products/AudioPriorityBar.app"

xcodebuild \
  -project "$root/AudioPriorityBar.xcodeproj" \
  -scheme AudioPriorityBar \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -arch arm64 -arch x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CONFIGURATION_BUILD_DIR="$products" \
  CURRENT_PROJECT_VERSION="$build_number" \
  SPARKLE_FEED_URL="$feed_url" \
  SPARKLE_PUBLIC_KEY="$public_key" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  "$root/scripts/sign-app.sh" "$app"
fi

actual_version=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
actual_build=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
[[ "$actual_version" == "$version" ]]
[[ "$actual_build" == "$build_number" ]]
actual_feed=$(/usr/libexec/PlistBuddy \
  -c "Print :SUFeedURL" "$app/Contents/Info.plist")
[[ "$actual_feed" == "$feed_url" ]]
actual_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$app/Contents/Info.plist")
[[ "$actual_key" == "$public_key" ]]

architectures=$(/usr/bin/lipo -archs \
  "$app/Contents/MacOS/AudioPriorityBar")
[[ " $architectures " == *" arm64 "* ]]
[[ " $architectures " == *" x86_64 "* ]]
test -s "$app/Contents/Resources/LICENSE"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
(
  cd "$staging"
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
  # Sparkle picks the delta matching the installed build and falls back to
  # the full archive when none applies.
  deltas=""
  for old_zip in ${PREVIOUS_RELEASES:+"$PREVIOUS_RELEASES"/*.zip}; do
    [[ -f "$old_zip" ]] || continue
    old_dir=$(mktemp -d "$staging/.previous.XXXXXXXX")
    /usr/bin/ditto -x -k "$old_zip" "$old_dir"
    old_plist="$old_dir/AudioPriorityBar.app/Contents/Info.plist"
    old_feed=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$old_plist" 2>/dev/null || true)
    old_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$old_plist" 2>/dev/null || true)
    [[ "$old_feed" == "$feed_url" && "$old_key" == "$public_key" ]] || continue
    old_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$old_plist")
    old_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$old_plist")
    [[ "$old_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$old_build" =~ ^[0-9]+$ ]] || continue
    delta="AudioPriorityBar-from-$old_version.delta"
    "$sparkle_bin/BinaryDelta" create "$old_dir/AudioPriorityBar.app" "$app" "$staging/$delta"
    deltas+="
        <enclosure url=\"$download_base/$delta\" sparkle:deltaFrom=\"$old_build\" type=\"application/octet-stream\" $(sign "$staging/$delta")/>"
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
  # Verify the published archive against the key embedded in the app. This
  # also catches a fork configured with another maintainer's public key.
  archive_signature=$(/usr/bin/xmllint --xpath 'string(//item/enclosure/@*[local-name()="edSignature"])' "$appcast")
  /usr/bin/swift - "$public_key" "$archive_signature" "$update_zip" <<'SWIFT'
import CryptoKit
import Foundation
guard let keyData = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      key.isValidSignature(signature, for: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe))
else {
    FileHandle.standardError.write(Data("Update signature does not match SPARKLE_PUBLIC_KEY.\n".utf8))
    exit(1)
}
SWIFT
  cp "$appcast" "$app_appcast"
fi

# A shared export directory can contain another project's appcast. Only
# remove stale artifacts recorded by our own previous successful run.
manifest=.audio-priority-bar-artifacts
if [[ -f "$output_dir/$manifest" && ! -L "$output_dir/$manifest" ]]; then
  while IFS= read -r name; do
    case "$name" in
      appcast.xml|appcast-app.xml|AudioPriorityBar-update.zip) ;;
      *) [[ "$name" =~ ^AudioPriorityBar-from-[0-9]+\.[0-9]+\.[0-9]+\.delta$ ]] || continue ;;
    esac
    [[ -e "$staging/$name" ]] || rm -f "$output_dir/$name"
  done < "$output_dir/$manifest"
fi
for asset in "$staging"/*; do
  echo "${asset##*/}" >> "$staging/$manifest"
  mv -f "$asset" "$output_dir/"
done
mv -f "$staging/$manifest" "$output_dir/"

echo "Packaged AudioPriorityBar $version ($build_number)"
echo "Architectures: $architectures"
cat "$output_dir/AudioPriorityBar.zip.sha256"
