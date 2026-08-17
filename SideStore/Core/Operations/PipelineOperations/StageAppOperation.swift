//
//  StageAppOperation.swift
//  SideStore
//
//  Created by Magesh K on 31/7/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
@preconcurrency import AltSign

final class StageAppOperation: BasePipelineOperation<InstallAppOperationContext, ALTApplication>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> ALTApplication {
        debugLog("[StageAppOperation] execute() started")
        defer { debugLog("[StageAppOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)
        
        if let appBundle = self.context.targetAppBundle,
           appBundle.bundle.bundleURL.path.contains("SideBackup") || appBundle.bundle.bundleURL.path.contains("AltBackup"),
           let installedApp = self.context.installedApp {
            self.context.targetAppBundle = ALTApplication(fileURL: installedApp.fileURL)
        }
        
        guard let appBundle = self.context.targetAppBundle else {
            throw OperationError.invalidParameters("StageAppOperation: context.appBundle is nil")
        }
        
        let fileURL = appBundle.fileURL
        let tempDir = self.context.temporaryDirectory
        
        self.setProgress(30)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        if fileURL.path.hasPrefix(tempDir.path) {
            debugLog("[StageAppOperation] App is already in temporary directory: \(fileURL)")
            self.setProgress(100)
            return appBundle
        }
        
        let destinationURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
        debugLog("[StageAppOperation] Copying cached app from \(fileURL) to \(destinationURL)")
        
        self.setProgress(60)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            debugLog("[StageAppOperation] Removing pre-existing app bundle at destination: \(destinationURL)")
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        self.setProgress(80)
        debugLog("[StageAppOperation] Copying item from \(fileURL) to \(destinationURL)")
        try FileManager.default.copyItem(at: fileURL, to: destinationURL)
        debugLog("[StageAppOperation] Successfully copied app bundle to destination.")
        
        guard let stagedAppBundle = ALTApplication(fileURL: destinationURL) else {
            throw OperationError.invalidApp
        }
        
        self.context.targetAppBundle = stagedAppBundle
        self.setProgress(100)
        return stagedAppBundle
    }
}
