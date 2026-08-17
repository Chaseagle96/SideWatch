//
//  RemoveAppOperation.swift
//  SideStore
//
//  Created by Magesh K on 3/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import CoreData

final class RemoveAppOperation: BasePipelineOperation<InstallAppOperationContext, InstalledApp>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> InstalledApp {
        debugLog("[RemoveAppOperation] execute() started")
        defer { debugLog("[RemoveAppOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        guard let installedApp = self.context.installedApp else {
            throw OperationError.invalidParameters("RemoveAppOperation: self.context.installedApp is nil")
        }
        
        guard let backgroundContext = self.context.dbBackgroundContext else {
            throw OperationError.invalidParameters("RemoveAppOperation: context.dbBackgroundContext is nil")
        }
        
        await backgroundContext.perform {
            let installedAppInContext = backgroundContext.object(with: installedApp.objectID) as! InstalledApp
            backgroundContext.delete(installedAppInContext)
        }
        
        self.setProgress(100)
        return installedApp
    }
}
