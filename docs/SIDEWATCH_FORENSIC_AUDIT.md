# SideWatch forensic baseline

## Upstream fork point

The imported source is based on SideStore's `develop` commit
`e3f3a5b941ce657723a4939c89f2eea63bcfe263`. The source-transfer archive did
not retain SideStore's `.git` directory, so this was established by comparing
Git blob identities against that upstream tree: 574 of the 582 upstream files
present in the import match byte-for-byte. The eight differing files are the
pre-existing SideWatch edits in application discovery, provisioning, signing,
installation persistence, and refresh. Vendored submodule contents account
for most files that exist only in the import.

The SideWatch repository imported that snapshot at
`864e439d7f9e68f44717e84f97457357faef0521`. The failing artifact analyzed
below was then built from `4ce8fdab2b5893940b45e3ddd37ebabecaaf5679`.

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

## Representative Watch fixture

`SkillingTime-Watch-Unsigned.ipa` was used as the real Watch-bearing structural
fixture (SHA-256
`7dec4f509496a3959764d5c96187a33475cb65f59d0a3eb89741c1a9cc32163c`).
Recursive inspection found the following provisioned hierarchy and verified
all original cross-bundle relationships:

| Component | Platform | Bundle identifier | Relationship |
|---|---|---|---|
| Root app | iOS | `com.projectskillbook.app` | root |
| Widget | iOS | `com.projectskillbook.app.SkillingTimeWidgets` | embedded iOS extension |
| Watch app | watchOS | `com.projectskillbook.app.watchkitapp` | `WKCompanionAppBundleIdentifier` points to the root |
| Watch extension | watchOS | `com.projectskillbook.app.watchkitapp.watchkitextension` | `WKAppBundleIdentifier` points to the Watch app |

The fixture's executables are arm64 for iOS and arm64/arm64_32 for watchOS.
It is intentionally unsigned, so it was suitable for discovery, mapping,
relationship, archive, and signing-order validation but not for a
credentialed installation claim.

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
