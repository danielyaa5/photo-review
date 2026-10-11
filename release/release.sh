#!/bin/bash
# Builds a release: signed with Developer ID, notarized by Apple, stapled and zipped.
#
#   TEAM_ID=XXXXXXXXXX release/release.sh 0.2.0
#
# Needs xcodegen (brew install xcodegen) and Xcode signed in to a paid Apple Developer team. Signing and the
# notarization upload go through that Xcode account, so no password or key is handled here.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: TEAM_ID=XXXXXXXXXX release/release.sh VERSION}"
TEAM_ID="${TEAM_ID:?set TEAM_ID to your Apple Developer team ID}"
# Each version builds in its own folder, so making a release never deletes a copy that is still running.
BUILD="build/$VERSION"
ARCHIVE="$BUILD/PhotoReview.xcarchive"

rm -rf "$BUILD" PhotoReview.xcodeproj
mkdir -p "$BUILD"

# The release has its own bundle id, so it never shares macOS permissions with a local build.sh build.
sed 's/local\.photo-review/io.github.danielyaa5.photo-review/' ../Info.plist > build/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" build/Info.plist

xcodegen generate --quiet
xcodebuild -project PhotoReview.xcodeproj -scheme PhotoReview -configuration Release \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID" archive -quiet

cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>destination</key><string>upload</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$BUILD/export" -allowProvisioningUpdates -quiet

echo "Uploaded. Waiting for Apple to notarize it…"
until xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$BUILD/notarized" >/dev/null 2>&1; do
  sleep 20
done

APP="$BUILD/notarized/Photo Review.app"
spctl -a -vv "$APP"
# The same file name every time, so the website's download button can always point at the latest release.
ditto -c -k --keepParent "$APP" "$BUILD/PhotoReview.zip"
echo "Built release/$BUILD/PhotoReview.zip"
