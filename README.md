# MxU Slides

A native macOS presentation app for churches: lyrics, slides, media, timers, stage displays, NDI and DeckLink output, and live streaming. Everything runs on this Mac: no account, no server.

MxU Slides is source-available under the PolyForm Shield License 1.0.0. See [LICENSE.md](LICENSE.md).

What the license allows:

- [x] Use it for any purpose, including commercially and in production, at a church, a venue, or a business
- [x] Read, modify, and build on the source
- [x] Fork it and distribute copies or modified versions, as long as the license and its notice travel with them
- [x] Contribute changes back

What it does not allow:

- [ ] Providing a product that competes with MxU Slides, or with any product MxU provides using it, even if that product is free, uses a different interface or platform, or is written in another language
- [ ] Removing or altering the license text or the required notice

The full terms, including what happens if MxU later ships a product that competes with yours and the rules for discontinued products, are in [LICENSE.md](LICENSE.md).

## Getting started

Requirements:

- An Apple silicon Mac running macOS 14 or newer, with Xcode 26 or newer (Swift 6.2 toolchain)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Node 24 (`.tool-versions`) for the schema codegen and the drive scripts
- Optional, for NDI inputs and outputs: install the [NDI SDK for Apple](https://ndi.video/for-developers/ndi-sdk/) at `/Library/NDI SDK for Apple`. Without it `NDIKit` builds a stub and NDI is unavailable in the app. After installing or removing the SDK, delete `~/Library/Caches/org.swift.swiftpm/manifests` and use Product › Clean Build Folder. `apps/mac/scripts/release-dmg.sh` still requires it.
- Optional, for ProPresenter import: `brew install protobuf swift-protobuf`, then run `apps/mac/scripts/generate-propresenter-proto.sh`. Without the generated types `ProImport` builds a stub and the import menu reports that it is unavailable. `apps/mac/scripts/release-dmg.sh` still requires them.

The Blackmagic DeckLink SDK headers are vendored, so DeckLink output needs no install to build.

Build and run:

```bash
cd apps/mac
xcodegen generate
xcodebuild -project MxUSlides.xcodeproj -scheme MxUSlides -configuration Debug build
open "$(xcodebuild -project MxUSlides.xcodeproj -scheme MxUSlides -configuration Debug -showBuildSettings 2>/dev/null | awk '/TARGET_BUILD_DIR/{print $3; exit}')/MxU Slides.app"
```

Or open `MxUSlides.xcodeproj` in Xcode after `xcodegen generate` and run the `MxUSlides` scheme. Re-run `xcodegen generate` whenever you add or remove source files. The project is generated; its shared `Package.resolved` is checked in to pin the app's dependencies. Update it deliberately when adding optional ProPresenter support or upgrading packages.

## Building and testing

Each package builds and tests on its own with SwiftPM. None of them needs the NDI SDK (`NDIKit` builds a stub without it):

```bash
cd apps/mac/Packages
swift test --package-path PresenterCore
swift test --package-path SlideScene
swift test --package-path RenderEngine
swift test --package-path OutputEngine
swift test --package-path LocalAPI
swift test --package-path ProImport
```

Run `bash scripts/check.sh` from the repository root to check generated schemas and scripts, test all 12 packages, and build the app. The `source`, `swift`, and `app` arguments run those checks separately. Script checks also need Python 3 and zsh. Hardware and optional-SDK tests may skip when their prerequisites are absent.

Debug builds are ad-hoc signed (`CODE_SIGN_IDENTITY: "-"` in `apps/mac/project.yml`), so a fresh clone builds and runs without an Apple developer account. Production builds require an `MXU_BUNDLE_ID` you control and a Developer ID signing identity; helper identifiers follow the app's identifier automatically.

### Document schema

Edit `packages/schema/documents.json`, then regenerate:

```bash
node packages/schema/codegen.mjs
```

That rewrites `PresenterCore/Sources/PresenterCore/Generated/Models.swift` and `LocalAPI/Sources/LocalAPI/Resources/document-schemas.json`. Fields added after a type ships must be optional so existing libraries keep decoding.

### Release build

`apps/mac/scripts/release-dmg.sh` builds, Developer ID-signs, notarizes, and staples a DMG. It expects `DEVELOPER_ID_IDENTITY` and `MXU_BUNDLE_ID`, a `notarization-profile` entry in your Keychain (`xcrun notarytool store-credentials`), the NDI SDK's redistributable license file, and the ProPresenter types from `apps/mac/scripts/generate-propresenter-proto.sh`. It includes the app and third-party licenses before signing.

**Binary release is currently blocked:** the SRT XCFramework bundles OpenSSL 3.3.2. The release script refuses this unsupported dependency. See [docs/RELEASING.md](docs/RELEASING.md) for the remaining release gates and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for provenance.

### Local API

With Settings › Local API enabled, the app serves a REST and WebSocket API on port 6980, authenticated by scoped bearer tokens created in the same pane. `GET /v1/status` returns the live slide; `scripts/*.mjs` show it driving a show. The route table and OpenAPI document live in `apps/mac/Packages/LocalAPI`.

The API is off by default. When enabled it is reachable on the local network and uses unencrypted HTTP/WebSocket traffic; use a trusted network or an encrypted tunnel. Manage (`edit`) access is required to read stream presets because they can include ingest credentials. Revoking a key blocks subsequent requests and ends connected WebSockets on their next message or event; an already-authorized request may finish.

### Perf and diagnostics scripts

- `apps/mac/scripts/perf/run.sh` runs the scripted editor and animation perf check against a staged build and compares with `baseline.json`.
- `apps/mac/scripts/hitch-report.py` summarizes the main-thread hitches recorded in the app's breadcrumb logs (Help › Report a Problem saves them as a zip).
- `apps/mac/scripts/hls-sink.mjs` / `hls-replay.mjs` stand in for an HLS ingest endpoint when testing streaming.

## Contributing

Pull requests are welcome. By submitting one you agree that your contribution is licensed to MxU under the terms in [LICENSE.md](LICENSE.md). The MxU name and logos are trademarks and are not covered by the license.
