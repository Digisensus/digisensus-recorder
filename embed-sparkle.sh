#!/bin/bash
# Copies Sparkle.framework (from the SwiftPM build) into an app bundle and signs its parts.
# Usage: embed-sparkle.sh <App.app> <build dir> <signing identity> [extra codesign flags...]
# The XPC services are only needed by sandboxed apps; this one isn't, so they are left out,
# as Sparkle's documentation allows.
set -euo pipefail
APP="$1"; BIN="$2"; IDENTITY="$3"; shift 3

FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$FW"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"

# Nested code first, then the framework that seals it.
codesign --force "$@" --sign "$IDENTITY" "$FW/Versions/B/Autoupdate"
codesign --force "$@" --sign "$IDENTITY" "$FW/Versions/B/Updater.app"
codesign --force "$@" --sign "$IDENTITY" "$FW"
