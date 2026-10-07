#!/bin/bash
set -euo pipefail

PIN=1b63dda196eb7e079721a8a4a7e7773520cb5ad2
OUT="$(cd "$(dirname "$0")/.." && pwd)/Packages/ProImport/Sources/ProImport/Generated"
PROTOS="applicationInfo action alphaType alignmentGuide collectionElementType calendar audio background digitalAudio customOptions cue color font fileProperties effects hotKey groups input graphicsData macros layers intRange messages planningCenter musicKeyScale presentation playlist presentationSlide proAudienceLook propDocument proMask propSlide recording proworkspace propresenter proscreen stage rvtimestamp screens url template slide uuid templateIdentification version timers"

command -v protoc >/dev/null && command -v protoc-gen-swift >/dev/null || {
    echo "protoc / protoc-gen-swift missing: brew install protobuf swift-protobuf" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git clone -q https://github.com/greyshirtguy/ProPresenter7-Proto "$TMP/src"
git -C "$TMP/src" checkout -q "$PIN"

rm -rf "$OUT"; mkdir -p "$OUT"
(cd "$TMP/src/autogen-proto" && protoc --swift_out="$OUT" --swift_opt=Visibility=Public $(printf '%s.proto ' $PROTOS))
rm -rf ~/Library/Caches/org.swift.swiftpm/manifests
echo "$(ls "$OUT" | wc -l | tr -d ' ') files → $OUT (Xcode: Product › Clean Build Folder before the next build)"
