#!/bin/bash
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: bundle-licenses.sh APP DERIVED_DATA}"
DERIVED="${2:?Usage: bundle-licenses.sh APP DERIVED_DATA}"
DEST="$APP/Contents/Resources/Licenses"
CHECKOUTS="$DERIVED/SourcePackages/checkouts"
mkdir -p "$DEST"

copy_notice() {
  [ -s "$1" ] || { echo "Missing required notice: $1" >&2; exit 1; }
  cp "$1" "$DEST/$2"
}

copy_notice "$MAC_DIR/../../LICENSE.md" MxU-Slides-LICENSE.md
copy_notice "$MAC_DIR/../../THIRD_PARTY_NOTICES.md" THIRD_PARTY_NOTICES.md
copy_notice "$MAC_DIR/Packages/automerge-swift/LICENSE" Automerge-LICENSE.txt
copy_notice "$MAC_DIR/Packages/StreamEngine/Sources/StreamEngine/HLS/Vendored/VendoredLICENSE.md" HLS-Vendored-LICENSE.txt
copy_notice "$CHECKOUTS/FlyingFox/LICENSE" FlyingFox-LICENSE.txt
copy_notice "$CHECKOUTS/HaishinKit.swift/LICENSE.md" HaishinKit-LICENSE.txt
copy_notice "$CHECKOUTS/Logboard/LICENSE.md" Logboard-LICENSE.txt
for notice in "$MAC_DIR"/ThirdPartyLicenses/*.txt; do
  copy_notice "$notice" "$(basename "$notice")"
done

# Preserve the SDK's complete notice, including its redistribution conditions.
sed -n '/-LICENSE-START-/,/-LICENSE-END-/p' \
  "$MAC_DIR/Packages/DeckLinkKit/Sources/CDeckLink/Vendor/DeckLinkAPI.h" \
  > "$DEST/DeckLink-NOTICE.txt"
[ -s "$DEST/DeckLink-NOTICE.txt" ] || { echo 'Missing DeckLink notice' >&2; exit 1; }

if [ -d "$MAC_DIR/Packages/ProImport/Sources/ProImport/Generated" ]; then
  copy_notice "$CHECKOUTS/swift-protobuf/LICENSE.txt" SwiftProtobuf-LICENSE.txt
  if [ -f "$CHECKOUTS/swift-protobuf/NOTICE.txt" ]; then
    copy_notice "$CHECKOUTS/swift-protobuf/NOTICE.txt" SwiftProtobuf-NOTICE.txt
  fi
fi
