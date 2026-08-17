//
//  ALTSigner.swift
//  AltSign
//

import Foundation
import SwiftBridge


public final class ALTSigner: NSObject {

    // MARK: Properties

    public var team: ALTTeam
    public var certificate: ALTCertificate

    // MARK: Init

    public init(team: ALTTeam, certificate: ALTCertificate) {
        NSError.registerErrorProviders()
        self.team = team
        self.certificate = certificate
        super.init()
    }

    // MARK: Public API (IDENTICAL SIGNATURE)

    public func signApp(
        at appURL: URL,
        provisioningProfiles profiles: [ALTProvisioningProfile],
        completionHandler: @escaping (Bool, Error?) -> Void
    ) -> Progress {

        debugLog("[AltSign] ALTSigner.signApp called at URL: \(appURL.path)")
        debugLog("[AltSign] Provisioning profiles provided: \(profiles.map { "\($0.name) (\($0.bundleIdentifier))" })")

        let progress = Progress(totalUnitCount: 1)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.performSigning(
                    appURL: appURL,
                    profiles: profiles,
                    progress: progress
                )

                verboseLog("[AltSign] ALTSigner.signApp completed successfully for URL: \(appURL.path)")
                completionHandler(true, nil)
            } catch {
                verboseLog("[AltSign] ALTSigner.signApp failed with error: \(error)")
                completionHandler(false, error)
            }
        }

        return progress
    }
}

// MARK: - Core Signing Logic

private extension ALTSigner {

    func performSigning(
        appURL: URL,
        profiles: [ALTProvisioningProfile],
        progress: Progress
    ) throws {

        guard let application = ALTApplication(fileURL: appURL) else {
            debugLog("[AltSign] ALTSigner.performSigning error: Failed to parse ALTApplication at \(appURL.path)")
            throw NSError(
                domain: AltSignErrorDomain,
                code: ALTError.invalidApp.rawValue
            )
        }

        debugLog("[AltSign] ALTSigner.performSigning started for app: \(application.bundleIdentifier)")

        func profile(for app: ALTApplication) -> ALTProvisioningProfile? {
            if let exactProfile = profiles.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                return exactProfile
            }

            // A user may elect to reuse the main iOS profile for ordinary
            // app extensions. Never apply that fallback to a watchOS bundle:
            // watchOS binaries require a watchOS profile and would otherwise
            // produce an IPA that looks signed but cannot be installed.
            guard !app.isWatchOSBundle else { return nil }

            // If an ordinary extension was intentionally configured to use
            // the main profile, the shortest available bundle ID is the
            // parent application's profile. This is deterministic and avoids
            // relying on Dictionary/Set iteration order.
            return profiles.min { lhs, rhs in
                lhs.bundleIdentifier.count < rhs.bundleIdentifier.count
            }
        }

        var entitlementsByURL: [URL: String] = [:]

        func prepare(_ app: ALTApplication) throws {
            verboseLog("[AltSign] ALTSigner.prepare started for: \(app.bundleIdentifier)")

            guard let profile = profile(for: app) else {
                verboseLog("[AltSign] ALTSigner.prepare error: Missing provisioning profile for \(app.bundleIdentifier)")
                throw NSError(
                    domain: AltSignErrorDomain,
                    code: ALTError.missingProvisioningProfile.rawValue
                )
            }

            let profileURL =
                app.fileURL.appendingPathComponent("embedded.mobileprovision")

            verboseLog("[AltSign] Writing mobileprovision to: \(profileURL.path)")
            try profile.data.write(to: profileURL)

            verboseLog("[AltSign] Original profile entitlements: \(profile.entitlements)")
            let applicationEntitlements = app.entitlements
            var filtered = profile.entitlements

            for (key, _) in profile.entitlements {
                if let applicationValue = applicationEntitlements[key] {
                    if key == ALTEntitlementKeychainAccessGroups {
                        guard let groups = applicationValue as? [String] else {
                            verboseLog("The app's keychain-access-groups entitlement is not an array of strings.")
                            continue
                        }
                        
                        filtered[key] = try groups.map { group in
                            guard let separator = group.firstIndex(of: ".") else {
                                throw NSError(
                                    domain: AltSignErrorDomain,
                                    code: ALTError.invalidApp.rawValue,
                                    userInfo: [NSLocalizedFailureReasonErrorKey: "The keychain access group '\(group)' does not contain a Team ID prefix."]
                                )
                            }
                            
                            return profile.teamIdentifier + group[separator...]
                        }
                    }
                } else if key != ALTEntitlementApplicationIdentifier &&
                            key != ALTEntitlementTeamIdentifier &&
                            key != ALTEntitlementGetTaskAllow {
                    filtered.removeValue(forKey: key)
                }
            }

            verboseLog("[AltSign] Filtered entitlements for signing: \(filtered)")

            let stringKeyed = Dictionary(uniqueKeysWithValues: filtered.map { ($0.key.rawValue, $0.value) })
            let plist = try PropertyListSerialization.data(
                fromPropertyList: stringKeyed,
                format: .xml,
                options: 0
            )

            guard let string = String(data: plist, encoding: .utf8) else {
                verboseLog("[AltSign] ALTSigner.prepare error: Failed to convert plist data to XML string")
                throw NSError(
                    domain: AltSignErrorDomain,
                    code: ALTError.unknown.rawValue
                )
            }

            verboseLog("[AltSign] Prepared Entitlements XML:\n\(string)")

            entitlementsByURL[
                app.fileURL.resolvingSymlinksInPath()
            ] = string
        }

        try prepare(application)

        for embedded in application.allEmbeddedApplications.sorted(by: { $0.fileURL.path < $1.fileURL.path }) {
            verboseLog("[AltSign] Found embedded bundle: \(embedded.bundleIdentifier) at \(embedded.fileURL.path) (watchOS: \(embedded.isWatchOSBundle))")
            try prepare(embedded)
        }

        // ---- LDID SIGNING VIA NATIVE BRIDGE ----

        let keyData = try certificate.unencryptedP12Data()

        // The bundled ldid implementation understands iOS app extensions,
        // but older ldid releases do not discover the special
        // `Watch/*.app` location used by Xcode for WatchKit companions. Sign
        // each watch application as its own bundle first. Its nested
        // WatchKit extension is then discovered through the normal
        // `PlugIns/*.appex` traversal. The final parent-app signing pass still
        // hashes the already-signed Watch directory as part of the iOS app's
        // resource seal.
        for watchApplication in application.watchApplications.sorted(by: { $0.fileURL.path < $1.fileURL.path }) {
            verboseLog("[AltSign] Signing embedded watchOS application: \(watchApplication.fileURL.path)")
            try LdidBridge.sign(
                appPath: watchApplication.fileURL.path,
                keyData: keyData,
                entitlementProvider: { path in
                    let url = path.isEmpty
                        ? watchApplication.fileURL
                        : watchApplication.fileURL.appendingPathComponent(path)
                    let xml = entitlementsByURL[url.resolvingSymlinksInPath()] ?? ""
                    verboseLog("[AltSign] Ldid watch entitlementProvider queried path: '\(path)', returning xml (length: \(xml.count))")
                    return xml
                },
                progress: {
                    progress.completedUnitCount += 1
                }
            )
        }
        
        verboseLog("[AltSign] Invoking LdidBridge.sign for appPath: \(application.fileURL.path)")
        try LdidBridge.sign(
            appPath: application.fileURL.path,
            keyData: keyData,
            entitlementProvider: { path in
                let url: URL

                if path.isEmpty {
                    url = application.fileURL
                } else {
                    url = application.fileURL
                        .appendingPathComponent(path)
                }

                let xml = entitlementsByURL[
                    url.resolvingSymlinksInPath()
                ] ?? ""
                verboseLog("[AltSign] Ldid entitlementProvider queried path: '\(path)', returning xml (length: \(xml.count))")
                return xml
            },
            progress: {
                progress.completedUnitCount += 1
            }
        )
    }
}
