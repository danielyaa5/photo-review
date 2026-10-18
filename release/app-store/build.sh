#!/bin/bash
# Builds a local App Store candidate; this script never uploads or submits it.
set -euo pipefail
cd "$(dirname "$0")"
TEAM_ID="${TEAM_ID:?set TEAM_ID to your Apple Developer team ID}"
xcodegen generate --quiet
xcodebuild -project PhotoReviewStore.xcodeproj -scheme PhotoReviewStore \
  -configuration Debug -derivedDataPath ../build/app-store-preview \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID" build -quiet
