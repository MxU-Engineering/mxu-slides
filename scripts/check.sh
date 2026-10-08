#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-all}"
case "$MODE" in all|source|swift|app) ;; *) echo "Usage: $0 [all|source|swift|app]" >&2; exit 2 ;; esac

if [[ "$MODE" == all || "$MODE" == source ]]; then
  node packages/schema/codegen.mjs
  git diff --exit-code -- \
    apps/mac/Packages/PresenterCore/Sources/PresenterCore/Generated/Models.swift \
    apps/mac/Packages/LocalAPI/Sources/LocalAPI/Resources/document-schemas.json
  while IFS= read -r file; do
    if [[ "$(head -n 1 "$file")" == '#!/bin/zsh' ]]; then
      zsh -n "$file"
    else
      bash -n "$file"
    fi
  done < <(git ls-files '*.sh')
  while IFS= read -r file; do node --check "$file"; done < <(git ls-files '*.mjs')
  bash apps/mac/scripts/test-hitch-report.sh
  bash apps/mac/scripts/perf/test-perf-scripts.sh
fi

if [[ "$MODE" == all || "$MODE" == swift ]]; then
  for package in PresenterCore SlideScene RenderEngine MediaEngine AudioEngine OutputEngine LocalAPI PPTXImport ProImport NDIKit StreamEngine DeckLinkKit; do
    echo "Testing $package"
    swift test --package-path "apps/mac/Packages/$package" \
      --scratch-path "$ROOT/.build/release-check" --jobs "${SWIFT_BUILD_JOBS:-4}"
  done
fi

if [[ "$MODE" == all || "$MODE" == app ]]; then
  xcodegen generate --spec apps/mac/project.yml --project apps/mac
  xcodebuild -project apps/mac/MxUSlides.xcodeproj -scheme MxUSlides \
    -configuration Debug -destination 'generic/platform=macOS' \
    -derivedDataPath "$ROOT/.build/app" \
    -onlyUsePackageVersionsFromResolvedFile build
fi
