# Releasing MxU Slides

## Publishing the source

- Review and merge the release-readiness changes after both CI checks pass (`Source checks` and `macOS build and tests`).
- Confirm MxU has the rights to publish the source, vendored SDK code, fixtures, and branding under the existing PolyForm Shield terms. Keep third-party licenses intact.
- Review every branch/tag and any issue, pull request, or attachment that will become visible. Run a full-history secret scan immediately before changing visibility.
- Configure branch protection and GitHub's available secret-scanning/push-protection settings for public contributions.
- Change repository visibility only as an explicit owner action. Source publication does not imply the app has completed binary-release validation.

## Blocking binary dependency

HaishinKit 2.2.5 resolves `libsrt.xcframework` 1.5.4, SHA-256 `76879e2802e45ce043f52871a0a6764d57f833bdb729f2ba6663f4e31d658c4a`. Its macOS static archive identifies OpenSSL 3.3.2. This is outside the [currently supported OpenSSL lines](https://openssl-library.org/policies/releasestrat/index.html), and [3.3.3 fixed security issues present in 3.3.2](https://github.com/openssl/openssl/blob/openssl-3.3.3/CHANGES.md). Exploitability in this app has not been established.

Before distributing an app, upgrade or rebuild the SRT dependency with a supported, patched OpenSSL version. Verify its source revisions, build inputs, checksums, and license/source notices. The historical build script did not pin its OpenSSL checkout; simply copying license text cannot establish binary provenance. Update `THIRD_PARTY_NOTICES.md`, `apps/mac/ThirdPartyLicenses`, dependency pins, and the dependency gate together. Test SRT on a real receiver after the replacement.

## Building a distributable app

1. Choose a production reverse-DNS `MXU_BUNDLE_ID` and set `DEVELOPER_ID_IDENTITY` to the authorized Developer ID Application identity. The app, XPC helpers, and API Keychain namespace follow the bundle ID.
2. Install the NDI SDK, confirm its runtime redistribution terms, and generate the ProPresenter types. Resolve dependencies and review the resulting lockfile changes.
3. Run `bash scripts/check.sh`. Run the SDK-enabled NDI and ProPresenter tests in addition to the stub configuration CI covers.
4. Set the release version and build number. Build from a clean, reviewed commit. Run `bash apps/mac/scripts/release-dmg.sh`. `NOTARIZATION_PROFILE` can override the default Keychain profile name.
5. Verify both helpers are signed and embedded, all license notices are present, and the DMG is notarized and stapled. Install on a clean Apple silicon Mac without developer tools or SDKs.
6. Exercise imports, library backup/restore, show controls, audio/video playback, recording, RTMP/HLS/SRT streaming, NDI, and physical DeckLink outputs. Include the minimum supported macOS version (14) and current macOS. Record hardware and skipped checks.
7. Publish the DMG, its SHA-256, version, source commit, and release notes. Keep signing keys and unredacted diagnostics out of the repository; retain dSYMs privately for support.

CI uses ad-hoc signing and optional-SDK stubs. It does not validate Developer ID signing, notarization, NDI redistribution, physical capture/output devices, or older macOS runtime compatibility.
