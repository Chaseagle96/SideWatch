# SideWatch forensic baseline

## Artifact inspected

- GitHub Actions run: `32035318434` (run number 8)
- Source commit: `4ce8fdab2b5893940b45e3ddd37ebabecaaf5679`
- Artifact: `SideStore.ipa`
- SHA-256: `fdbc39d0f64e229ca1289ee0f38abf60e187d34dd9752332febc267d4b30574f`

The separately supplied `SideWatch-8.ipa` is byte-for-byte identical to that
Actions artifact.

## Self-install failure

The artifact is not a device-signed IPA. The workflow built with
`CODE_SIGNING_ALLOWED=NO`, applied ldid development/fake signatures, and then
zipped the product. Mechanical inspection found no `embedded.mobileprovision`
in the root app or widget, no root or widget
`_CodeSignature/CodeResources`, and no resource seal for the embedded
AltSign framework. Consequently, direct installation necessarily fails Apple
application verification before launch.

No device-side `MIInstallerErrorDomain` or `IXUserPresentableErrorDomain`
record was supplied with this artifact, so a more specific numeric
MobileInstallation code cannot be claimed. If an external installer first
re-signs this input, the resulting signed IPA and the nested device error log
are a different artifact and must be inspected separately.

| Check | Expected | Run 8 actual | Result |
|---|---|---|---|
| Payload structure | exactly one `Payload/*.app` | `Payload/SideStore.app` | PASS |
| Main executable | present, executable | `SideStore` present, arm64 | PASS |
| Root profile | matches root ID/device | missing | FAIL |
| Widget profile | matches widget ID/device | missing | FAIL |
| Root resource seal | `_CodeSignature/CodeResources` | missing | FAIL |
| Widget resource seal | `_CodeSignature/CodeResources` | missing | FAIL |
| Nested framework seals | valid | incomplete | FAIL |
| Signed installability | recursive validation | invalid | FAIL |
| Device installation | successful | no device evidence | NOT TESTED |

## Architectural finding

The inherited SideStore model understood a root application plus immediate
`PlugIns/*.appex` children. Its ldid traversal did not recognize
`Watch/*.app` or `WatchKit/*.app`, provisioning and persistence were flat, and
profile-only refresh did not rebuild the embedded Watch profiles or reseal the
parent IPA. The pre-existing SideWatch workaround signed one Watch level
separately, but it did not make discovery, identity mapping, provisioning,
relationship rewriting, persistence, or refresh graph-aware.

The replacement architecture is documented in
`SIDEWATCH_SIGNING_ARCHITECTURE.md`. Its device/profile/signature claims remain
unverified until a credentialed run signs for a registered iPhone and Apple
Watch and both installations are observed.
