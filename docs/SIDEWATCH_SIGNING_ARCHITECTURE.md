# SideWatch signing architecture

## Upstream boundary

SideStore historically models a root `ALTApplication` plus the app extensions
immediately below `PlugIns/`. Its ldid bundle recursion signs frameworks and
`PlugIns/*.appex`, but did not classify `Watch/*.app` or `WatchKit/*.app` as
nested signed bundles. The legacy refresh path installs renewed provisioning
profiles on the iPhone without rebuilding or reinstalling the IPA.

Those assumptions are insufficient for a Watch-bearing IPA. A Watch app is a
separately identified and provisioned application bundle, can contain its own
frameworks and extensions, and carries cross-bundle identifiers that must move
with the iOS root identifier.

## Bundle graph

`ALTSignedBundleNode` represents applications, extensions, frameworks, and
dynamic libraries. Discovery is recursive across `PlugIns`, `Watch`,
`WatchKit`, and `Frameworks`. Its post-order traversal is the signing schedule:
children first, iOS root last.

Applications and extensions are provisioning units. Frameworks and dylibs are
signed code but never receive application provisioning profiles.

## Lifecycle

1. **Discover** the complete signed-bundle graph.
2. **Map IDs** with `ALTBundleIdentifierMapping`. Root-prefixed IDs preserve
   their hierarchy; unrelated child IDs receive a stable collision-safe suffix.
3. **Rewrite relationships** including `WKCompanionAppBundleIdentifier`,
   `WKAppBundleIdentifier`, and containing-app references.
4. **Provision** every application and extension with an exact App ID/profile.
   Root-profile reuse for distinct nested bundles is rejected.
5. **Check Watch registration** against registered Watch devices and the
   returned profile's `ProvisionedDevices` list.
6. **Reconcile entitlements** with the selected profile, rewrite Team-prefixed
   keychain groups, use provisioned App Groups, report removed capabilities,
   and reject identifier/team/profile contradictions. The signer also rejects
   expired profiles and profiles that do not authorize the selected signing
   certificate.
7. **Sign nested code** through ldid's recursive bundle traversal. The ldid
   recursion now treats `Watch/*.app` and `WatchKit/*.app` as nested bundles;
   frameworks are sealed without inheriting application entitlements.
8. **Validate relationships** before signing and run the recursive IPA validator
   after packaging.
9. **Seal the root** only after all descendants have been signed.
10. **Package** exactly one `Payload/*.app`, preserving modes and safe symlinks.
    Both the runtime ZIP bridge and CI's Info-ZIP invocation preserve framework
    symlinks instead of dereferencing them into a different bundle layout.
11. **Install** through SideStore's existing minimuxer installation path.
12. **Refresh** ordinary apps with the upstream profile-refresh path. Apps with
    a Watch companion take the full stage, provision, re-sign, package, send,
    and reinstall path so the embedded Watch profiles and signatures are
    renewed as well.

## Physical-device provisioning boundary

Apple documents Apple Watch as its own registered device family and requires
registered devices when generating development profiles. Apple's installation
troubleshooting note specifically directs developers to add the phone and
paired Watch UDIDs when diagnosing provisioning-profile installation failures.
SideWatch therefore requests watchOS profiles for Watch application and
extension nodes, rejects a team with no registered Watch, and verifies that a
returned Watch profile contains a registered Watch identifier.

- [Apple Developer: Devices overview](https://developer.apple.com/help/account/devices/devices-overview/)
- [Apple Developer: Create a development provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile/)
- [Apple Technical Note TN2319](https://developer.apple.com/library/archive/technotes/tn2319/)

## CI artifact classification

The repository has no Apple signing identity, private key, registered device
UDID, or device-specific profiles. CI therefore emits
`SideWatch-Unsigned.ipa`, classified as `UNSIGNED_ALT_SERVER_INPUT`. CI proves
that it compiles and is structurally valid, and also asserts that signed
installability validation fails. This prevents an unsigned artifact from being
misrepresented as installable.

Only a credentialed/device-specific run may claim `STRUCTURALLY VERIFIED` for
signatures. Only a real iPhone installation may claim `INSTALL VERIFIED`. Only
successful transfer to a paired Watch may claim `WATCH VERIFIED`.

## Validator

`scripts/validate_ipa.py` recursively reports every component's platform,
bundle ID, profile application identifier, team, signature material,
relationships, and result. On macOS, `--verify-codesign` verifies each node in
post-order with `codesign --verify --strict`; it does not use `codesign --deep`
as a signing strategy. `--device-udid` and `--watch-device-udid` additionally
require every relevant profile to contain the intended physical device.
