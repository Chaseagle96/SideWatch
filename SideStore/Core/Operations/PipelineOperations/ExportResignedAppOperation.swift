//
//  ExportResignedAppOperation.swift
//  SideStore
//
//  Created by Magesh K on 30/07/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation
@preconcurrency import AltSign

final class ExportResignedAppOperation: BasePipelineOperation<InstallAppOperationContext, URL>, @unchecked Sendable {

    override func execute(parentProgress: Progress?) async throws -> URL {
        debugLog("[ExportResignedAppOperation] execute() started")
        defer { debugLog("[ExportResignedAppOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)

        guard let resignedAppBundle = self.context.resignedAppBundle else {
            throw OperationError.invalidParameters("ExportResignedAppOperation: context.resignedAppBundle is nil")
        }

        guard UserDefaults.standard.isExportResignedAppEnabled else {
            self.setProgress(100)
            return resignedAppBundle.fileURL
        }

        let sourceURL = resignedAppBundle.fileURL
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let resignedAppsURL = documentsURL.appendingPathComponent("ResignedApps")
        self.setProgress(30)
        do {
            if !FileManager.default.fileExists(atPath: resignedAppsURL.path) {
                try FileManager.default.createDirectory(at: resignedAppsURL, withIntermediateDirectories: true, attributes: nil)
            }
        } catch {
            debugLog("Failed to create ResignedApps folder: \(error)")
            throw error
        }

        let utis = Bundle(url: resignedAppBundle.fileURL)?.infoDictionary?[Bundle.Info.exportedUTIs] as? [[String: Any]]
        let isSideBackup = utis?.first?["UTTypeDescription"] as? String == "SideStore Backup App"
        let destPath = isSideBackup ? resignedAppBundle.name + "-sidebackup" : resignedAppBundle.name
        let destinationURL = resignedAppsURL.appendingPathComponent(destPath + ".app")
        self.setProgress(60)
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
        } catch {
            debugLog("Failed to delete existing file at destination: \(error)")
            throw error
        }
        self.setProgress(80)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            debugLog("File copied to: \(destinationURL.path)")
        } catch {
            debugLog("Failed to copy file to destination: \(error)")
            throw error
        }
        self.setProgress(100)
        return destinationURL
    }
}
