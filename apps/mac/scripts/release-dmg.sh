#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${DEVELOPER_ID_IDENTITY:?set DEVELOPER_ID_IDENTITY to your Developer ID Application signing identity}"
PROFILE="notarization-profile"
DIST="$MAC_DIR/build/dist"
DERIVED="$MAC_DIR/build/release-deriveddata"
APP="$DERIVED/Build/Products/Release/MxU Slides.app"

BUILD_NUMBER="$(git -C "$MAC_DIR" rev-list --count HEAD)"
GIT_COMMIT="$(git -C "$MAC_DIR" rev-parse --short=10 HEAD)"
if [ -n "$(git -C "$MAC_DIR" status --porcelain --untracked-files=no -- "$MAC_DIR/../..")" ]; then
  GIT_COMMIT="$GIT_COMMIT-dirty"
fi
echo "==> Build $BUILD_NUMBER, commit $GIT_COMMIT"

PROTO_DIR="$MAC_DIR/Packages/ProImport/Sources/ProImport/Generated"
[ -d "$PROTO_DIR" ] || { echo "ProPresenter protobuf sources missing at $PROTO_DIR: run apps/mac/scripts/generate-propresenter-proto.sh first" >&2; exit 1; }
[ -f "/Library/NDI SDK for Apple/include/Processing.NDI.Lib.h" ] || { echo "NDI SDK for Apple missing at /Library/NDI SDK for Apple" >&2; exit 1; }
rm -rf ~/Library/Caches/org.swift.swiftpm/manifests

echo "==> Generating the Xcode project"
xcodegen generate --spec "$MAC_DIR/project.yml" --project "$MAC_DIR" | tail -1

echo "==> Building Release (arm64)"
xcodebuild -project "$MAC_DIR/MxUSlides.xcodeproj" \
  -scheme MxUSlides -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MXU_GIT_COMMIT="$GIT_COMMIT" \
  build | tail -5

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$DIST/MxU-Slides-$VERSION.dmg"
rm -rf "$DIST" && mkdir -p "$DIST"

DSYM="$APP.dSYM"
[ -d "$DSYM" ] || { echo "No dSYM at $DSYM" >&2; exit 1; }
ditto "$DSYM" "$DIST/$(basename "$DSYM")"
xcrun dwarfdump --uuid "$APP/Contents/MacOS/MxU Slides" "$DIST/$(basename "$DSYM")"

NDI_DYLIB="$APP/Contents/XPCServices/NDIHelper.xpc/Contents/Frameworks/libndi.dylib"
NDI_LICENSES="/Library/NDI SDK for Apple/lib/macOS/libndi_licenses.txt"
[ -f "$NDI_DYLIB" ] || { echo "NDI redist not embedded at $NDI_DYLIB" >&2; exit 1; }
cp "$NDI_LICENSES" "$APP/Contents/Resources/"

echo "==> Signing with Developer ID + hardened runtime"
codesign --force --timestamp --sign "$IDENTITY" "$NDI_DYLIB"
for HELPER in "$APP"/Contents/XPCServices/*.xpc; do
  codesign --force --options runtime --timestamp \
    --entitlements "$MAC_DIR/Signing/Helper.entitlements" \
    --sign "$IDENTITY" "$HELPER"
done
codesign --force --options runtime --timestamp \
  --entitlements "$MAC_DIR/Signing/MxUSlides.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" "$DIST/app.zip"
xcrun notarytool submit "$DIST/app.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$DIST/app.zip"

echo "==> Building the DMG"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MxU Slides" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Gatekeeper check"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "Done: $DMG (build $BUILD_NUMBER, commit $GIT_COMMIT), dSYM beside it"
