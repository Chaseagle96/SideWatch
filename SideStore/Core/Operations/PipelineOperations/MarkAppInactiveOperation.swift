//
//  MarkAppInactiveOperation.swift
//  SideStore
//
//  Created by Magesh K on 3/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import CoreData

final class MarkAppInactiveOperation: BasePipelineOperation<InstallAppOperationContext, InstalledApp>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> InstalledApp {
        debugLog("[MarkAppInactiveOperation] execute() started")
        defer { debugLog("[MarkAppInactiveOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        guard let installedApp = self.context.installedApp else {
            throw OperationError.invalidParameters("MarkAppInactiveOperation: self.context.installedApp is nil")
        }
        
        guard let backgroundContext = self.context.dbBackgroundContext else {
            throw OperationError.invalidParameters("MarkAppInactiveOperation: context.dbBackgroundContext is nil")
        }
        
        let result = await backgroundContext.perform {
            let installedAppInContext = backgroundContext.object(with: installedApp.objectID) as! InstalledApp
            installedAppInContext.isActive = false
            return installedAppInContext
        }
        
        self.setProgress(100)
        return result
    }
}
