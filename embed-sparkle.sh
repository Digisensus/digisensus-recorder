#!/bin/bash
set -euo pipefail
APP="$1"; BIN="$2"; IDENTITY="$3"; shift 3

FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$FW"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"

codesign --force "$@" --sign "$IDENTITY" "$FW/Versions/B/Autoupdate"
codesign --force "$@" --sign "$IDENTITY" "$FW/Versions/B/Updater.app"
codesign --force "$@" --sign "$IDENTITY" "$FW"
