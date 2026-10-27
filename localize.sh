#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

STRINGS=.build/l10n-strings
CATALOG=Resources/Localizable.xcstrings
rm -rf .build/l10n "$STRINGS"
swift build --scratch-path .build/l10n --product DigisensusRecorder \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$STRINGS"
[ -f "$CATALOG" ] || echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "$CATALOG"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$STRINGS"/*.stringsdata
echo "Synced $(xcrun xcstringstool print "$CATALOG" | grep -c . ) strings into $CATALOG"
