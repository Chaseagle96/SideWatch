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
            profiles.first(where: { $0.bundleIdentifier == app.bundleIdentifier })
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

            guard profile.expirationDate > Date() else {
                throw NSError(
                    domain: AltSignErrorDomain,
                    code: ALTError.invalidApp.rawValue,
                    userInfo: [
                        NSLocalizedFailureReasonErrorKey:
                            "Provisioning profile '\(profile.name)' for '\(app.bundleIdentifier)' expired on \(profile.expirationDate)."
                    ]
                )
            }
            guard profile.certificates.contains(where: {
                $0.serialNumber.caseInsensitiveCompare(certificate.serialNumber) == .orderedSame
            }) else {
                throw NSError(
                    domain: AltSignErrorDomain,
                    code: ALTError.invalidApp.rawValue,
                    userInfo: [
                        NSLocalizedFailureReasonErrorKey:
                            "Signing certificate '\(certificate.serialNumber)' is not authorized by profile '\(profile.name)' for '\(app.bundleIdentifier)'."
                    ]
                )
            }

            let profileURL =
                app.fileURL.appendingPathComponent("embedded.mobileprovision")

            verboseLog("[AltSign] Writing mobileprovision to: \(profileURL.path)")
            try profile.data.write(to: profileURL)

            verboseLog("[AltSign] Original profile entitlements: \(profile.entitlements)")
            let reconciliation = try ALTEntitlementReconciler.reconcile(
                applicationEntitlements: app.entitlements,
                profile: profile,
                bundleIdentifier: app.bundleIdentifier
            )
            let filtered = reconciliation.entitlements
            for diagnostic in reconciliation.diagnostics {
                debugLog("[AltSign][Entitlements][\(app.bundleIdentifier)] \(diagnostic)")
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

        let provisioningApplications = application.provisioningApplications
        let duplicateIdentifiers = Dictionary(grouping: provisioningApplications, by: \.bundleIdentifier)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        guard duplicateIdentifiers.isEmpty else {
            throw NSError(
                domain: AltSignErrorDomain,
                code: ALTError.invalidApp.rawValue,
                userInfo: [
                    NSLocalizedFailureReasonErrorKey:
                        "Multiple provisioned bundles use the same identifier: \(duplicateIdentifiers.joined(separator: ", "))."
                ]
            )
        }

        for embedded in provisioningApplications {
            verboseLog("[AltSign] Preparing provisioning unit: \(embedded.bundleIdentifier) at \(embedded.fileURL.path) (watchOS: \(embedded.isWatchOSBundle))")
            try prepare(embedded)
        }

        // ---- LDID SIGNING VIA NATIVE BRIDGE ----

        let keyData = try certificate.unencryptedP12Data()

        // ldid's bundle traversal includes PlugIns, Frameworks, Watch, and
        // WatchKit. Its recursive Sign call is post-order, so the complete
        // graph is signed deepest-first and the iOS root is sealed last.
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
