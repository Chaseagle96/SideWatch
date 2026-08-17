//
//  ResignAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 6/7/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
@preconcurrency import AltSign

final class ResignAppOperation: BasePipelineOperation<InstallAppOperationContext, ALTApplication>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> ALTApplication {
        debugLog("[ResignAppOperation] execute() started")
        defer { debugLog("[ResignAppOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        guard
            let appBundle = self.context.targetAppBundle,
            let profiles = self.context.provisioningProfiles,
            let team = self.context.authenticatedContext.team,
            let certificate = self.context.overrideCertificate ?? self.context.authenticatedContext.signingCertificate
        else {
            throw OperationError.invalidParameters("ResignAppOperation.main: " +
                                                   "self.context.authenticatedContext.team or " +
                                                   "self.context.provisioningProfiles or " +
                                                   "self.context.authenticatedContext.signingCertificate is nil")
        }
        
        debugLog("[ResignAppOperation] Resigning app \(self.context.bundleIdentifier)...")
        
        self.setProgress(5)
        
        let effectiveBundleId = self.context.targetBundleIdentifier
        
        let appBundleURL = try await self.prepareAppBundle(for: appBundle, profiles: profiles, appexBundleIds: context.appexBundleIds ?? [:])
        
        self.setProgress(40)
        
        let resignedURL = try await self.resignAppBundle(at: appBundleURL, team: team, certificate: certificate, profiles: Array(profiles.values))
        
        let updatedApp = AnyApp(
            name: appBundle.name,
            bundleIdentifier: effectiveBundleId,
            url: appBundle.fileURL,
            storeApp: appBundle.storeApp
        )
        let destinationURL = InstalledApp.refreshedIPAURL(for: updatedApp)
        try FileManager.default.copyItem(at: resignedURL, to: destinationURL, shouldReplace: true)
        self.debugLog("[ResignAppOperation] Successfully resigned app to \(destinationURL.absoluteString)")
        
        // Use appBundleURL since we need an app bundle, not .ipa.
        guard let resignedAppBundle = ALTApplication(fileURL: appBundleURL) else { throw OperationError.invalidApp }
        
        self.debugLog("[ResignAppOperation] Resigned app \(self.context.bundleIdentifier) to \(resignedAppBundle.bundleIdentifier).")
        
        self.setProgress(100)
        
        return resignedAppBundle
    }

    
    private func prepareAppBundle(for targetAppBundle: ALTApplication, profiles: [String: ALTProvisioningProfile], appexBundleIds: [String: String]) async throws -> URL {

        let bundleIdentifier = context.targetBundleIdentifier
        let finalBundleIdentifier: String
        // The profile dictionary also contains watchOS profiles. Never use an
        // arbitrary dictionary value for the root app: Swift dictionary order
        // is unspecified, and a watch profile would produce an iOS URL scheme
        // and destination bundle ID.
        if let profile = profiles[bundleIdentifier] ?? (context.useMainProfile ? profiles.values.first : nil) {
            finalBundleIdentifier = profile.bundleIdentifier
        } else {
            finalBundleIdentifier = bundleIdentifier
        }
        
        // Use customized bundle ID if applicable
        let openURL = InstalledApp.openAppURL(for: AnyApp(from: targetAppBundle, bundleId: finalBundleIdentifier))
        let fileURL = targetAppBundle.fileURL

        let appBundleURL = self.context.temporaryDirectory.appendingPathComponent("App.app")
        if fileURL.path != appBundleURL.path {
            if FileManager.default.fileExists(atPath: appBundleURL.path) {
                try FileManager.default.removeItem(at: appBundleURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: appBundleURL)
        }
        
        guard let appBundle = Bundle(url: appBundleURL) else { throw ALTError(.missingAppBundle) }
        guard let infoDictionary = appBundle.completeInfoDictionary else { throw ALTError(.missingInfoPlist) }
        
        // replace scheme targets to match the bundle suffix so multiple instances can be correctly routed for helper apps like SideBackup
        var allURLSchemes = infoDictionary[Bundle.Info.urlTypes] as? [[String: Any]] ?? []
        allURLSchemes.removeAll { urlType in
            guard let schemes = urlType["CFBundleURLSchemes"] as? [String] else { return false }
            return schemes.contains { $0.hasPrefix("sidestore-") }
        }
        
        let altstoreURLScheme = ["CFBundleTypeRole": "Editor",
                                 "CFBundleURLName": finalBundleIdentifier,
                                 "CFBundleURLSchemes": [openURL.scheme!]] as [String : Any]
        allURLSchemes.append(altstoreURLScheme)
        
        var additionalValues: [String: Any] = [Bundle.Info.urlTypes: allURLSchemes]

        if targetAppBundle.isAltStoreApp {
            guard let udid = try await fetchUDID() else { throw OperationError.unknownUDID }
            guard Bundle.main.object(forInfoDictionaryKey: Bundle.Info.devicePairingString) is String else { throw OperationError.unknownUDID }
            additionalValues[Bundle.Info.devicePairingString] = "<insert pairing file here>"
            additionalValues[Bundle.Info.deviceID] = udid
            additionalValues[Bundle.Info.serverID] = UserDefaults.standard.preferredServerID
            
            if let activeCert = CertificateManager.shared.activeCertificate {
                additionalValues[Bundle.Info.certificateID] = activeCert.serialNumber
                try activeCert.p12Data.write(to: appBundle.certificateURL, options: .atomic)
            } else {
                self.verboseLog("[ResignAppOperation] No activeCertificate found in CertificateManager. Embedded certificate + certificate identifier in app bundle will not be updated.")
            }
        } else if infoDictionary.keys.contains(Bundle.Info.deviceID), let udid = try await fetchUDID() {
            // There is an ALTDeviceID entry, so assume the app is using AltKit and replace it with the device's UDID.
            additionalValues[Bundle.Info.deviceID] = udid
            additionalValues[Bundle.Info.serverID] = UserDefaults.standard.preferredServerID
        }
        
        // Prepare app
        try self.prepare(appBundle, bundleID: bundleIdentifier, additionalInfoDictionaryValues: additionalValues, profiles: profiles, appexBundleIds: appexBundleIds)
        try self.prepareEmbeddedBundles(
            in: appBundle,
            originalRootBundleIdentifier: targetAppBundle.bundleIdentifier,
            effectiveRootBundleIdentifier: bundleIdentifier,
            profiles: profiles,
            appexBundleIds: appexBundleIds,
            includeWatchApplications: true
        )
        try self.removeMissingAppExtensionReferences(from: appBundle)
        
        return appBundleURL
    }

    /// Rewrites and prepares every nested bundle that will be signed. The
    /// standard iOS path is `PlugIns/*.appex`; a WatchKit companion lives in
    /// `Watch/*.app` and has its own nested `PlugIns/*.appex` directory.
    private func prepareEmbeddedBundles(
        in parentBundle: Bundle,
        originalRootBundleIdentifier: String,
        effectiveRootBundleIdentifier: String,
        profiles: [String: ALTProvisioningProfile],
        appexBundleIds: [String: String],
        includeWatchApplications: Bool
    ) throws {
        let fileManager = FileManager.default

        if let directory = parentBundle.builtInPlugInsURL,
           let urls = try? fileManager.contentsOfDirectory(
               at: directory,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for fileURL in urls.sorted(by: { $0.path < $1.path }) {
                #if DEBUG
                if fileURL.lastPathComponent.lowercased().contains(".xctest") {
                    try fileManager.removeItem(at: fileURL)
                    continue
                }
                #endif

                guard fileURL.pathExtension.caseInsensitiveCompare("appex") == .orderedSame,
                      let appExtension = Bundle(url: fileURL),
                      let originalBundleID = appExtension.bundleIdentifier else {
                    continue
                }

                let effectiveBundleID = Self.effectiveBundleIdentifier(
                    originalBundleID,
                    originalRootBundleIdentifier: originalRootBundleIdentifier,
                    effectiveRootBundleIdentifier: effectiveRootBundleIdentifier
                )
                try self.prepare(appExtension, bundleID: effectiveBundleID, profiles: profiles, appexBundleIds: appexBundleIds)
                try self.prepareEmbeddedBundles(
                    in: appExtension,
                    originalRootBundleIdentifier: originalRootBundleIdentifier,
                    effectiveRootBundleIdentifier: effectiveRootBundleIdentifier,
                    profiles: profiles,
                    appexBundleIds: appexBundleIds,
                    includeWatchApplications: false
                )
            }
        }

        guard includeWatchApplications,
              let rootApplication = ALTApplication(fileURL: parentBundle.bundleURL) else {
            return
        }

        for watchApplication in rootApplication.watchApplications.sorted(by: { $0.fileURL.path < $1.fileURL.path }) {
            guard let watchBundle = Bundle(url: watchApplication.fileURL) else {
                throw ALTError(.missingAppBundle)
            }

            let effectiveBundleID = Self.effectiveBundleIdentifier(
                watchApplication.bundleIdentifier,
                originalRootBundleIdentifier: originalRootBundleIdentifier,
                effectiveRootBundleIdentifier: effectiveRootBundleIdentifier
            )
            try self.prepare(watchBundle, bundleID: effectiveBundleID, profiles: profiles, appexBundleIds: appexBundleIds)
            try self.prepareEmbeddedBundles(
                in: watchBundle,
                originalRootBundleIdentifier: originalRootBundleIdentifier,
                effectiveRootBundleIdentifier: effectiveRootBundleIdentifier,
                profiles: profiles,
                appexBundleIds: appexBundleIds,
                includeWatchApplications: false
            )
        }
    }

    private static func effectiveBundleIdentifier(
        _ originalIdentifier: String,
        originalRootBundleIdentifier: String,
        effectiveRootBundleIdentifier: String
    ) -> String {
        guard originalIdentifier != originalRootBundleIdentifier,
              originalIdentifier.hasPrefix(originalRootBundleIdentifier + ".") else {
            return originalIdentifier == originalRootBundleIdentifier ? effectiveRootBundleIdentifier : originalIdentifier
        }

        return effectiveRootBundleIdentifier + String(originalIdentifier.dropFirst(originalRootBundleIdentifier.count))
    }
    
    private func prepare(_ bundle: Bundle, bundleID identifier: String?, additionalInfoDictionaryValues: [String: Any] = [:], profiles: [String: ALTProvisioningProfile], appexBundleIds: [String: String]) throws {
        guard let identifier else {
            throw ALTError(.missingAppBundle)
        }
        let isWatchOSBundle = (bundle.infoDictionary?["CFBundleSupportedPlatforms"] as? [String])?.contains {
            $0.caseInsensitiveCompare("WatchOS") == .orderedSame
        } == true || (bundle.infoDictionary?["DTPlatformName"] as? String)?.caseInsensitiveCompare("watchos") == .orderedSame
            || (bundle.infoDictionary?["UIDeviceFamily"] as? [NSNumber])?.contains { $0.intValue == 4 } == true

        let profile = profiles[identifier] ?? (
            context.useMainProfile && !isWatchOSBundle
                ? profiles[context.targetBundleIdentifier]
                : nil
        )
        guard let profile else {
            throw ALTError(.missingProvisioningProfile)
        }
        guard var infoDictionary = bundle.completeInfoDictionary else {
            throw ALTError(.missingInfoPlist)
        }
        
        if let forcedBundleIdentifier = appexBundleIds[identifier] {
            infoDictionary[kCFBundleIdentifierKey as String] = forcedBundleIdentifier
        } else {
            infoDictionary[kCFBundleIdentifierKey as String] = profile.bundleIdentifier
        }

        func rewrittenBundleIdentifier(for originalIdentifier: String) -> String {
            let effectiveIdentifier = Self.effectiveBundleIdentifier(
                originalIdentifier,
                originalRootBundleIdentifier: context.bundleIdentifier,
                effectiveRootBundleIdentifier: context.targetBundleIdentifier
            )

            if effectiveIdentifier == context.targetBundleIdentifier {
                return profiles[context.targetBundleIdentifier]?.bundleIdentifier ?? effectiveIdentifier
            }

            return appexBundleIds[effectiveIdentifier] ?? effectiveIdentifier
        }

        infoDictionary[Bundle.Info.altBundleID] = identifier
        infoDictionary[Bundle.Info.devicePairingString] = "<insert pairing file here>"
        infoDictionary.removeValue(forKey: "DTXcode")
        infoDictionary.removeValue(forKey: "DTXcodeBuild")

        // WatchKit stores the companion relationship outside of
        // CFBundleIdentifier. Keep those references in the same namespace as
        // the rewritten bundle IDs, otherwise installation can succeed while
        // the Watch app fails to launch or pair with its iOS companion.
        if isWatchOSBundle {
            if infoDictionary["CFBundleExecutable"] == nil,
               let executableName = Self.inferredExecutableName(for: bundle.bundleURL) {
                // A few WatchKit app containers omit this key even though
                // they carry a single direct Mach-O stub. ldid needs the key
                // to locate the file, so only infer it when the bundle has
                // exactly one recognizable candidate.
                infoDictionary["CFBundleExecutable"] = executableName
            }

            if let companionBundleIdentifier = infoDictionary["WKCompanionAppBundleIdentifier"] as? String {
                infoDictionary["WKCompanionAppBundleIdentifier"] = rewrittenBundleIdentifier(for: companionBundleIdentifier)
            }

            if var extensionInfo = infoDictionary["NSExtension"] as? [String: Any],
               var extensionAttributes = extensionInfo["NSExtensionAttributes"] as? [String: Any],
               let watchAppBundleIdentifier = extensionAttributes["WKAppBundleIdentifier"] as? String {
                extensionAttributes["WKAppBundleIdentifier"] = rewrittenBundleIdentifier(for: watchAppBundleIdentifier)
                extensionInfo["NSExtensionAttributes"] = extensionAttributes
                infoDictionary["NSExtension"] = extensionInfo
            }
        }

        for (key, value) in additionalInfoDictionaryValues {
            infoDictionary[key] = value
        }

        if let appGroups = profile.entitlements[.appGroups] as? [String] {
            infoDictionary[Bundle.Info.appGroups] = appGroups

            // To keep file providers working, remap the NSExtensionFileProviderDocumentGroup, if there is one.
            if var extensionInfo = infoDictionary["NSExtension"] as? [String: Any],
                let appGroup = extensionInfo["NSExtensionFileProviderDocumentGroup"] as? String,
                let localAppGroup = appGroups.filter({ $0.contains(appGroup) }).min(by: { $0.count < $1.count }) {
                extensionInfo["NSExtensionFileProviderDocumentGroup"] = localAppGroup
                infoDictionary["NSExtension"] = extensionInfo
            }
        }
        
        // Add app-specific exported UTI so we can check later if this app (extension) is installed or not.
        let installedAppUTI = ["UTTypeConformsTo": [],
                               "UTTypeDescription": "AltStore Installed App",
                               "UTTypeIconFiles": [],
                               "UTTypeIdentifier": InstalledApp.installedAppUTI(forBundleIdentifier: profile.bundleIdentifier),
                               "UTTypeTagSpecification": [:]] as [String : Any]
        
        var exportedUTIs = infoDictionary[Bundle.Info.exportedUTIs] as? [[String: Any]] ?? []
        exportedUTIs.append(installedAppUTI)
        infoDictionary[Bundle.Info.exportedUTIs] = exportedUTIs
        
        try (infoDictionary as NSDictionary).write(to: bundle.infoPlistURL)
        
        // Remove _CodeSignature folder (if it exists) because it will be added when resigning and it may have files that aren't overwritten when resigning
        // These files might be the cause of some ApplicationVerificationFailed errors
        let codeSignaturePath = bundle.bundleURL.appendingPathComponent("_CodeSignature").absoluteString.replacingOccurrences(of: "file://", with: "")
        if FileManager.default.fileExists(atPath: codeSignaturePath) {
            try FileManager.default.removeItem(atPath: codeSignaturePath)
            self.verboseLog("[ResignAppOperation] Removed _CodeSignature folder at \(codeSignaturePath)")
        }
    }

    private static func inferredExecutableName(for bundleURL: URL) -> String? {
        let machoMagics: Set<[UInt8]> = [
            [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCE],
            [0xCF, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF],
            [0xCA, 0xFE, 0xBA, 0xBE],
            [0xBE, 0xBA, 0xFE, 0xCA]
        ]

        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.compactMap { url -> String? in
            guard url.lastPathComponent != "Info.plist",
                  url.lastPathComponent != "PkgInfo",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let fileHandle = FileHandle(forReadingAtPath: url.path) else {
                return nil
            }

            let magic = Array(fileHandle.readData(ofLength: 4))
            fileHandle.closeFile()
            return machoMagics.contains(magic) ? url.lastPathComponent : nil
        } ?? []

        return candidates.count == 1 ? candidates[0] : nil
    }

    private func resignAppBundle(at fileURL: URL, team: ALTTeam, certificate: ALTCertificate, profiles: [ALTProvisioningProfile]) async throws -> URL {
        let signer = ALTSigner(team: team, certificate: certificate)
        try await signer.signApp(at: fileURL, provisioningProfiles: profiles, parentProgress: self.progress)
        return try FileManager.default.zipAppBundle(at: fileURL)
    }
    
    private func removeMissingAppExtensionReferences(from bundle: Bundle) throws {
        // If app extensions have been removed from an app (either by AltStore or the developer),
        // we must remove all references to them from SC_Info/Manifest.plist (if it exists).
        
        let scInfoURL = bundle.bundleURL.appendingPathComponent("SC_Info")
        let manifestPlistURL = scInfoURL.appendingPathComponent("Manifest.plist")
        
        guard let manifestPlist = NSMutableDictionary(contentsOf: manifestPlistURL), let sinfReplicationPaths = manifestPlist["SinfReplicationPaths"] as? [String] else { return }
        
        // Remove references to missing files.
        let filteredReplicationPaths = sinfReplicationPaths.filter { path in
            guard let fileURL = URL(string: path, relativeTo: bundle.bundleURL) else { return false }
            
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            return fileExists
        }
        
        manifestPlist["SinfReplicationPaths"] = filteredReplicationPaths
        
        // Save updated Manifest.plist to disk.
        try manifestPlist.write(to: manifestPlistURL)
    }
}

extension ALTSigner {
    func signApp(at fileURL: URL, provisioningProfiles: [ALTProvisioningProfile], parentProgress: Progress) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let progress = self.signApp(at: fileURL, provisioningProfiles: provisioningProfiles) { (success, error) in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: error ?? OperationError.unknown())
                }
            }
            parentProgress.addChild(progress, withPendingUnitCount: 50)
        }
    }
}
