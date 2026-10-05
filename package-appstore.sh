#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

find_identity() {
    local kind="$1"
    shift
    security find-identity -v "$@" | awk -F'"' -v kind="$kind" 'index($2, kind) == 1 {print $2; exit}'
}
APP_IDENTITY="${APP_IDENTITY:-$(find_identity "Apple Distribution" -p codesigning)}"
APP_IDENTITY="${APP_IDENTITY:-$(find_identity "3rd Party Mac Developer Application" -p codesigning)}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-$(find_identity "3rd Party Mac Developer Installer")}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-$(find_identity "Mac Installer Distribution")}"
[ -n "$APP_IDENTITY" ] || { echo "No Apple Distribution certificate in the keychain" >&2; exit 1; }
[ -n "$INSTALLER_IDENTITY" ] || { echo "No 3rd Party Mac Developer Installer certificate in the keychain" >&2; exit 1; }
[ -f "${APPSTORE_PROFILE:-}" ] || { echo "Set APPSTORE_PROFILE to the Mac App Store provisioning profile" >&2; exit 1; }

VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')}"
BUILD="${BUILD:-$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Set VERSION (e.g. 1.3.0) or tag the release v1.3.0" >&2; exit 1; }

BIN_ROOT=.build-appstore
swift build -c release --build-path "$BIN_ROOT" -Xswiftc -DAPP_STORE -Xlinker -dead_strip_dylibs
BIN="$BIN_ROOT/release"
if otool -L "$BIN/DigisensusRecorder" | grep -q Sparkle; then
    echo "The App Store build still links Sparkle" >&2
    exit 1
fi

NAME="Digisensus-Recorder-$VERSION-$BUILD-AppStore"
STAGE=dist/appstore
APP="$STAGE/Digisensus Recorder.app"
PKG="dist/$NAME.pkg"
rm -rf "$STAGE" "$PKG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DigisensusRecorder" "$APP/Contents/MacOS/DigisensusRecorder"
cp "$BIN/recorder" "$APP/Contents/MacOS/recorder"
cp Info.plist "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" "$PLIST"
for key in SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SUScheduledCheckInterval; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST"
done
cp Resources/AppIcon.icns Resources/MenuIcon.png Resources/MenuIcon@2x.png Resources/TitleMark.png Resources/TitleMark@2x.png "$APP/Contents/Resources/"
cp -R Resources/Licenses "$APP/Contents/Resources/Licenses"
cp NOTICE "$APP/Contents/Resources/Licenses/DigisensusRecorder-NOTICE.txt"
cp LICENSE "$APP/Contents/Resources/Licenses/DigisensusRecorder-LICENSE.txt"
rm -f "$APP/Contents/Resources/Licenses/Sparkle-"*.txt
cp "$APPSTORE_PROFILE" "$APP/Contents/embedded.provisionprofile"
xattr -cr "$APP"

codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    --entitlements RecorderHelper-AppStore.entitlements \
    --identifier com.digisensus.recorder.cli "$APP/Contents/MacOS/recorder"
codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    --entitlements DigisensusRecorder-AppStore.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
rm -rf "$STAGE"
echo "Packaged $PKG (version $VERSION, build $BUILD). Upload it with Transporter."
