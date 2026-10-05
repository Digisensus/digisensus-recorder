#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${CODESIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity in the keychain" >&2; exit 1; }
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" Info.plist 2>/dev/null || true)
[ -n "$PUBLIC_KEY" ] || { echo "Info.plist has no SUPublicEDKey: run generate_keys first (see release.sh)" >&2; exit 1; }

VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')}"
BUILD="${BUILD:-$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Set VERSION (e.g. 1.3.0) or tag the release v1.3.0" >&2; exit 1; }

swift build -c release
BIN=.build/release
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

NAME="Digisensus-Recorder-$VERSION-$BUILD"
STAGE=dist/stage
APP="$STAGE/Digisensus Recorder.app"
ZIP="dist/$NAME.zip"
DMG="dist/$NAME.dmg"
rm -rf "$STAGE" "$ZIP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DigisensusRecorder" "$APP/Contents/MacOS/DigisensusRecorder"
cp "$BIN/recorder" "$APP/Contents/MacOS/recorder"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" \
    "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuIcon.png Resources/MenuIcon@2x.png Resources/TitleMark.png Resources/TitleMark@2x.png "$APP/Contents/Resources/"
cp -R Resources/Licenses "$APP/Contents/Resources/Licenses"
cp NOTICE "$APP/Contents/Resources/Licenses/DigisensusRecorder-NOTICE.txt"
cp LICENSE "$APP/Contents/Resources/Licenses/DigisensusRecorder-LICENSE.txt"

./embed-sparkle.sh "$APP" "$BIN" "$IDENTITY" --timestamp --options runtime
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
    --identifier com.digisensus.recorder.cli "$APP/Contents/MacOS/recorder"
codesign --force --timestamp --options runtime --entitlements DigisensusRecorder.entitlements \
    --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" dist/notarize.zip
    xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    rm dist/notarize.zip
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
else
    echo "NOTARY_PROFILE not set: the app is signed but not notarized."
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIGNATURE=$("$SPARKLE_BIN/sign_update" -p "$ZIP")

ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Digisensus Recorder" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
rm -rf "$STAGE"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

cat > dist/release.env <<ENV
VERSION=$VERSION
BUILD=$BUILD
ZIP=$ZIP
DMG=$DMG
ED_SIGNATURE=$SIGNATURE
NOTARIZED=$([ -n "${NOTARY_PROFILE:-}" ] && echo yes || echo no)
ENV
echo "Packaged $ZIP and $DMG (version $VERSION, build $BUILD)"
