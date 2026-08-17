//
//  DeactivateAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 3/4/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
@preconcurrency import AltSign
import CoreData

final class DeactivateAppOperation: BasePipelineOperation<PipelineOperationContext, InstalledApp>, @unchecked Sendable
{
    let app: InstalledApp?
    
    init(app: InstalledApp?, context: PipelineOperationContext) throws {
        self.app = app
        try super.init(context: context)
    }
    
    override func execute(parentProgress: Progress?) async throws -> InstalledApp {
        debugLog("[DeactivateAppOperation] execute() started")
        defer { debugLog("[DeactivateAppOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)
        
        guard let backgroundContext = self.context.dbBackgroundContext else {
            throw OperationError.invalidParameters("DeactivateAppOperation: context.dbBackgroundContext is nil")
        }
        
        guard let app = self.app else {
            throw OperationError.invalidParameters("DeactivateAppOperation: target app is nil")
        }
        
        let appObjectID = app.objectID
        let installedApp = await backgroundContext.perform {
            backgroundContext.object(with: appObjectID) as! InstalledApp
        }

        try await self.performDeactivate(for: installedApp)
        
        let result = await backgroundContext.perform {
            backgroundContext.object(with:appObjectID) as! InstalledApp
        }
        self.setProgress(100)
        return result
    }
    
    @discardableResult
    private func performDeactivate(for installedApp: InstalledApp) async throws -> InstalledApp {
        let appExIdentifiers = installedApp.appExtensions.map { $0.resignedBundleIdentifier }
        let embeddedIdentifiers = ALTApplication(fileURL: installedApp.fileURL).map {
            Array($0.allEmbeddedApplications.map { $0.bundleIdentifier })
        } ?? []
        let allIdentifiers = Array(Set([installedApp.resignedBundleIdentifier] + appExIdentifiers + embeddedIdentifiers))

        var removedAny = false
        let count = allIdentifiers.count
        let startProgress = self.progress.completedUnitCount
        let endProgress: Int64 = 90
        let range = endProgress - startProgress
        
        for (index, identifier) in allIdentifiers.enumerated() {
            try await removeProvisioningProfile(identifier)
            if range > 0 {
                let percent = startProgress + Int64(Double(index + 1) / Double(count) * Double(range))
                self.setProgress(percent)
            }
            removedAny = true
        }
        guard removedAny else {
            throw OperationError.invalidParameters("DeactivateAppOperation: no profiles found to remove")
        }
        installedApp.isActive = false
        return installedApp
    }
}
