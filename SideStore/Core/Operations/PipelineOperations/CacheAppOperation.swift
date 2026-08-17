//
//  CacheAppOperation.swift
//  SideStore
//
//  Created by Magesh K on 30/07/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation

final class CacheAppOperation: BasePipelineOperation<InstallAppOperationContext, URL?>, @unchecked Sendable {

    override func execute(parentProgress: Progress?) async throws -> URL? {
        debugLog("[CacheAppOperation] execute() started")
        defer { debugLog("[CacheAppOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)

        guard let appBundle = context.targetAppBundle else {
            debugLog("[CacheAppOperation] context.appBundle is nil")
            self.setProgress(100)
            return nil
        }

        self.setProgress(40)
        let updatedApp = AnyApp(from: appBundle, bundleId: context.targetBundleIdentifier)
        let targetFileURL = InstalledApp.fileURL(for: updatedApp)
        
        self.setProgress(70)
        try FileManager.default.copyItem(at: appBundle.fileURL, to: targetFileURL, shouldReplace: true)
        
        self.setProgress(100)
        return targetFileURL
    }
}
