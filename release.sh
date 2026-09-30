#!/bin/bash
# Publishes a release over the air: tags it, packages it (package.sh, notarized), then uploads
# the update and the DMG to the backend's releases API through a port-forward to the admin port
# (the only way in; see the backend README).
#
#   NOTARY_PROFILE=<profile> ./release.sh 1.3.0 beta notes.md
#   NOTARY_PROFILE=<profile> CRITICAL=1 ./release.sh 1.3.1 stable notes.md
#
# Channel: beta (default) reaches only people who turned on beta versions; promote it to stable
# on the Releases page, or publish straight to stable. PHASED=1 spreads a stable release over 7
# days; CRITICAL=1 shows the update to everyone at once.
#
# One-time setup:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys   # keeps the private key in the login
#       keychain; put the printed public key in Info.plist (SUPublicEDKey) and in the backend's
#       APP_UPDATE_ED_PUBLIC_KEY. Back the private key up (generate_keys -x <file>).
#   xcrun notarytool store-credentials <profile> ...    # for NOTARY_PROFILE
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: release.sh <version> [beta|stable] [notes.md]}"
CHANNEL="${2:-beta}"
NOTES_FILE="${3:-}"
[[ "$CHANNEL" == beta || "$CHANNEL" == stable ]] || { echo "Channel is beta or stable" >&2; exit 1; }
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile}"
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first: a release is built from a commit" >&2; exit 1; }
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || { echo "No notes file $NOTES_FILE" >&2; exit 1; }

if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    [ "$(git rev-parse "v$VERSION^{commit}")" == "$(git rev-parse HEAD)" ] \
        || { echo "Tag v$VERSION exists on another commit" >&2; exit 1; }
else
    git tag -a "v$VERSION" -m "Digisensus Recorder $VERSION"
fi

VERSION="$VERSION" ./package.sh
# shellcheck source=/dev/null
source dist/release.env

PORT=18081
kubectl -n prod-recorder port-forward svc/recorder-backend-admin "$PORT:8081" >/dev/null &
FORWARD=$!
trap 'kill $FORWARD 2>/dev/null' EXIT
for _ in $(seq 1 20); do nc -z localhost "$PORT" 2>/dev/null && break; sleep 0.5; done

curl --fail-with-body -sS -H "X-Requested-By: release-script" \
    -F "zip=@$ZIP" -F "dmg=@$DMG" \
    -F "version=$VERSION" -F "build=$BUILD" -F "channel=$CHANNEL" -F "min_macos=15.0" \
    -F "ed_signature=$ED_SIGNATURE" \
    -F "notes=<${NOTES_FILE:-/dev/null}" \
    -F "critical=${CRITICAL:-0}" -F "phased=${PHASED:-0}" \
    "http://localhost:$PORT/api/releases"
echo
echo "Published $VERSION (build $BUILD) to $CHANNEL. Push the tag: git push origin v$VERSION"
