#!/bin/bash
set -euo pipefail
export LC_ALL=C

DERIVED="${1:?Usage: check-release-dependencies.sh DERIVED_DATA}"
SRT="$DERIVED/SourcePackages/artifacts/haishinkit.swift/libsrt/libsrt.xcframework/macos-arm64_x86_64/libsrt.a"
[ -s "$SRT" ] || { echo "Cannot audit the linked SRT library at $SRT" >&2; exit 1; }

# The 1.5.4 XCFramework used by HaishinKit 2.2.5 statically includes OpenSSL
# 3.3.2. A source-package audit does not see this transitive binary dependency.
VERSIONS="$(strings "$SRT" | sed -nE 's/^(OpenSSL [0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' | sort -u)"
[ -n "$VERSIONS" ] || { echo 'Cannot determine the bundled OpenSSL version; review the artifact before release.' >&2; exit 1; }
if echo "$VERSIONS" | grep -Eq '^OpenSSL 3\.[0-3]\.'; then
  echo "Release blocked: SRT includes an unsupported OpenSSL line: $VERSIONS" >&2
  echo 'Replace the SRT binary with a supported, patched build and verify its source and license notices. See docs/RELEASING.md.' >&2
  exit 1
fi
echo "SRT binary identifies $VERSIONS. Review current advisories and provenance before publishing."
