#!/bin/bash
# Builds "Photo Review.app" next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="Photo Review.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp index.html stats.html assets/icon.svg assets/AppIcon.icns "$APP/Contents/Resources/"
xcrun swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/PhotoReview" main.swift
# Identify the app by its bundle id rather than by the hash of this particular build. Otherwise macOS
# treats every rebuild as a new app and asks for Photos access again.
codesign --force --sign - -r='designated => identifier "local.photo-review"' "$APP"
echo "Built $APP"
