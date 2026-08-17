//
//  StageBackupAppOperation.swift
//  SideStore
//
//  Created by Magesh K on 30/07/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation
@preconcurrency import AltSign

final class StageBackupAppOperation: BasePipelineOperation<InstallAppOperationContext, InstalledApp>, @unchecked Sendable {
    let targetApp: InstalledApp?

    init(app: InstalledApp?, context: InstallAppOperationContext) throws {
        self.targetApp = app
        try super.init(context: context)
    }

    override func execute(parentProgress: Progress?) async throws -> InstalledApp {
        debugLog("[StageBackupAppOperation] execute() started")
        defer { debugLog("[StageBackupAppOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)
        
        guard let targetApp = self.targetApp else {
            debugLog("[StageBackupAppOperation] Error: target app is nil")
            throw OperationError.invalidParameters("StageBackupAppOperation: target app is nil")
        }
        
        debugLog("[StageBackupAppOperation] Preparing backup app stage for '\(targetApp.name)' (\(targetApp.bundleIdentifier)), target bundleID: '\(context.targetBundleIdentifier)'")
        
        guard ALTApplication(fileURL: targetApp.fileURL) != nil else {
            debugLog("[StageBackupAppOperation] Error: ALTApplication invalid/not found at \(targetApp.fileURL.path)")
            throw OperationError.appNotFound(name: targetApp.name)
        }

        self.setProgress(20)
        let temporaryDirectoryURL = context.temporaryDirectory.appendingPathComponent("SideBackup-" + UUID().uuidString)
        debugLog("[StageBackupAppOperation] Creating temp directory at \(temporaryDirectoryURL.path)")
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        guard let sidebackupFileURL = Bundle.main.url(forResource: "SideBackup", withExtension: "ipa") else {
            debugLog("[StageBackupAppOperation] Error: SideBackup.ipa resource not found in main bundle")
            throw OperationError.appNotFound(name: "SideBackup")
        }
        debugLog("[StageBackupAppOperation] Found SideBackup.ipa at \(sidebackupFileURL.path)")

        self.setProgress(40)
        debugLog("[StageBackupAppOperation] Unzipping SideBackup.ipa...")
        let unzippedAppBundleURL = try FileManager.default.unzipAppBundle(at: sidebackupFileURL, toDirectory: temporaryDirectoryURL)
        debugLog("[StageBackupAppOperation] Unzipped SideBackup app bundle to \(unzippedAppBundleURL.path)")
        
        guard let unzippedAppBundle = Bundle(url: unzippedAppBundleURL) else {
            debugLog("[StageBackupAppOperation] Error: Failed to instantiate Bundle at \(unzippedAppBundleURL.path)")
            throw OperationError.invalidApp
        }

        self.setProgress(70)
        if var infoDictionary = unzippedAppBundle.infoDictionary {
            debugLog("[StageBackupAppOperation] Updating Info.plist: CFBundleDisplayName='\(targetApp.name)', CFBundleIdentifier='\(context.targetBundleIdentifier)'")
            infoDictionary["CFBundleDisplayName"] = targetApp.name
            infoDictionary[kCFBundleIdentifierKey as String] = context.targetBundleIdentifier

            let targetAppBundle = ALTApplication(fileURL: targetApp.fileURL)
            var targetAppGroups = (targetAppBundle?.entitlements[.appGroups] as? [String]) ?? []
            if !targetAppGroups.contains(Bundle.baseAltStoreAppGroupID) {
                targetAppGroups.append(Bundle.baseAltStoreAppGroupID)
            }

            // replace sidebackup app's entitlements with target app's entilements (for appgroup!)
            infoDictionary[Bundle.Info.appGroups] = targetAppGroups
            context.additionalEntitlements[.appGroups] = targetAppGroups

            let installedAppUTI = [
                "UTTypeConformsTo": [],
                "UTTypeDescription": "SideStore Backup App",
                "UTTypeIconFiles": [],
                "UTTypeIdentifier": targetApp.installedBackupAppUTI,
                "UTTypeTagSpecification": [:]
            ] as [String: Any]

            var exportedUTIs = infoDictionary[Bundle.Info.exportedUTIs] as? [[String: Any]] ?? []
            exportedUTIs.append(installedAppUTI)
            infoDictionary[Bundle.Info.exportedUTIs] = exportedUTIs

            if let cachedAppBundle = ALTApplication(fileURL: targetApp.fileURL), let icon = cachedAppBundle.icon?.resizing(to: CGSize(width: 180, height: 180)) {
                let iconFileURL = unzippedAppBundleURL.appendingPathComponent("AppIcon.png")
                if let iconData = icon.pngData() {
                    try? iconData.write(to: iconFileURL, options: .atomic)
                    let bundleIcons = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": [iconFileURL.lastPathComponent]]]
                    infoDictionary["CFBundleIcons"] = bundleIcons
                    debugLog("[StageBackupAppOperation] Saved resized app icon to \(iconFileURL.path)")
                }
            }

            try (infoDictionary as NSDictionary).write(to: unzippedAppBundle.infoPlistURL)
            debugLog("[StageBackupAppOperation] Updated Info.plist written to \(unzippedAppBundle.infoPlistURL.path)")
        }

        self.setProgress(90)
        guard let sideBackupBundle = ALTApplication(fileURL: unzippedAppBundleURL) else {
            debugLog("[StageBackupAppOperation] Error: Failed to create ALTApplication for staged backup app at \(unzippedAppBundleURL.path)")
            throw OperationError.invalidApp
        }
        context.targetAppBundle = sideBackupBundle
        debugLog("[StageBackupAppOperation] Successfully set context.appBundle to staged SideBackup app ('\(sideBackupBundle.bundleIdentifier)')")
        self.setProgress(100)
        return targetApp
    }
}
