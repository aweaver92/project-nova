#!/usr/bin/env bash
#
# Build a Nova .ipa. macOS + Xcode only (xcodebuild cannot run on Windows/Linux).
#
# Usage:
#   scripts/build-ipa.sh                # unsigned .ipa (default) -> build/Nova-unsigned.ipa
#   SIGNED=1 scripts/build-ipa.sh       # signed .ipa via ExportOptions.plist -> build/export/NovaApp.ipa
#
# An UNSIGNED ipa cannot be installed straight to a device by Apple, but it is
# perfect for re-signing with AltStore / Sideloadly, or for inspection. For a
# device-installable build set SIGNED=1 and fill in Config/ExportOptions.plist
# (team id + signing style) plus valid signing assets in your keychain.
#
set -euo pipefail

cd "$(dirname "$0")/.."   # -> Nova/

SCHEME="NovaApp"
PROJECT="NovaApp.xcodeproj"
CONFIG="${CONFIG:-Release}"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/NovaApp.xcarchive"
SIGNED="${SIGNED:-0}"

echo "==> Generating Xcode project with XcodeGen"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

if [ "$SIGNED" = "1" ]; then
  echo "==> Archiving (signed)"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH"

  echo "==> Exporting signed .ipa"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "Config/ExportOptions.plist" \
    -exportPath "$BUILD_DIR/export"

  echo "==> Done: $BUILD_DIR/export/${SCHEME}.ipa"
else
  echo "==> Archiving (unsigned)"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS=""

  APP_PATH="$ARCHIVE_PATH/Products/Applications/${SCHEME}.app"
  if [ ! -d "$APP_PATH" ]; then
    echo "Could not find built .app at $APP_PATH" >&2
    exit 1
  fi

  echo "==> Packaging unsigned .ipa"
  rm -rf "$BUILD_DIR/Payload"
  mkdir -p "$BUILD_DIR/Payload"
  cp -R "$APP_PATH" "$BUILD_DIR/Payload/"
  ( cd "$BUILD_DIR" && zip -qr "Nova-unsigned.ipa" "Payload" && rm -rf "Payload" )

  echo "==> Done: $BUILD_DIR/Nova-unsigned.ipa (re-sign with AltStore/Sideloadly to install)"
fi
