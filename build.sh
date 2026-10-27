#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Digisensus Recorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DigisensusRecorder "$APP/Contents/MacOS/DigisensusRecorder"
cp .build/release/recorder "$APP/Contents/MacOS/recorder"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuIcon.png Resources/MenuIcon@2x.png Resources/TitleMark.png Resources/TitleMark@2x.png "$APP/Contents/Resources/"
if xcrun --find xcstringstool >/dev/null 2>&1; then
    for catalog in Resources/Localizable.xcstrings Resources/InfoPlist.xcstrings; do
        xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
    done
else
    echo "xcstringstool comes with Xcode; building in English only" >&2
fi
cp -R Resources/Licenses "$APP/Contents/Resources/Licenses"
cp NOTICE "$APP/Contents/Resources/Licenses/DigisensusRecorder-NOTICE.txt"
cp LICENSE "$APP/Contents/Resources/Licenses/DigisensusRecorder-LICENSE.txt"
IDENTITY="${CODESIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
./embed-sparkle.sh "$APP" .build/release "${IDENTITY:--}" --timestamp=none
codesign --force --timestamp=none --sign "${IDENTITY:--}" --identifier com.digisensus.recorder.cli "$APP/Contents/MacOS/recorder"
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$APP"

echo "Built $APP"
