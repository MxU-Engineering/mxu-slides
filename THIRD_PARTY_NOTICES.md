# Third-party notices

Third-party components retain their own licenses; the project's PolyForm Shield terms do not replace them. The release script places this inventory and license texts in `MxU Slides.app/Contents/Resources/Licenses` before signing.

| Component | Source / version | License text |
| --- | --- | --- |
| Automerge Swift and FFI | [automerge-swift 0.7.2](https://github.com/automerge/automerge-swift/tree/0.7.2); Swift sources are vendored locally | `apps/mac/Packages/automerge-swift/LICENSE` (MIT) |
| FlyingFox / FlyingSocks | [FlyingFox](https://github.com/swhitty/FlyingFox); see app and package lockfiles | Resolved checkout `LICENSE` (MIT) |
| HaishinKit and vendored HLS code | [HaishinKit 2.2.5](https://github.com/HaishinKit/HaishinKit.swift/tree/2.2.5) | Resolved checkout `LICENSE.md` and `HLS/Vendored/VendoredLICENSE.md` (BSD 3-Clause) |
| Logboard | [Logboard 2.6.0](https://github.com/shogo4405/Logboard/tree/2.6.0) | Resolved checkout `LICENSE.md` (BSD 3-Clause) |
| SRT | [Haivision SRT 1.5.4 source](https://github.com/Haivision/srt/tree/v1.5.4), distributed by [libsrt-xcframework](https://github.com/HaishinKit/libsrt-xcframework/releases/tag/v1.5.4) | `apps/mac/ThirdPartyLicenses/SRT-LICENSE.txt` (MPL 2.0) |
| OpenSSL inside the SRT archive | The currently resolved binary identifies [OpenSSL 3.3.2](https://github.com/openssl/openssl/tree/openssl-3.3.2) | `apps/mac/ThirdPartyLicenses/OpenSSL-LICENSE.txt` (Apache 2.0) |
| ProPresenter schema definitions (optional generated import code) | [ProPresenter7-Proto at 1b63dda](https://github.com/greyshirtguy/ProPresenter7-Proto/tree/1b63dda196eb7e079721a8a4a7e7773520cb5ad2) | `apps/mac/ThirdPartyLicenses/ProPresenter7-Proto-LICENSE.txt` (MIT) |
| SwiftProtobuf (optional) | [apple/swift-protobuf](https://github.com/apple/swift-protobuf), version recorded when import types are generated | Resolved checkout `LICENSE.txt` and any `NOTICE.txt` (Apache 2.0 with Runtime Library Exception) |
| Blackmagic DeckLink SDK headers and dispatch code | Vendored under `apps/mac/Packages/DeckLinkKit/Sources/CDeckLink/Vendor` | Each file's complete Blackmagic license notice; [SDK EULA](https://www.blackmagicdesign.com/EULA/DeckLinkSDK) |
| NDI runtime (optional, required by the full release script) | Installed NDI SDK for Apple | SDK-supplied `libndi_licenses.txt`, copied into app resources; the SDK's redistribution terms also apply |

The historical SRT binary's build script pins SRT but does not pin its OpenSSL checkout. The source links above identify upstream versions; they do not establish a reproducible source match for that binary. Before distributing a DMG, replace it with a supported OpenSSL build, verify the corresponding source and build inputs, and update this inventory and license bundle. Review transitive native dependencies in the replacement, as well as any NDI distribution requirements. See [the release checklist](docs/RELEASING.md).
