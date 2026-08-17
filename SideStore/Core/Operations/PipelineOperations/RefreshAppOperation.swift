//
//  RefreshAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 2/27/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CoreData
@preconcurrency import AltSign

final class RefreshAppOperation: BasePipelineOperation<InstallAppOperationContext, InstalledApp>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> InstalledApp {
        debugLog("[RefreshAppOperation] execute() started")
        defer { debugLog("[RefreshAppOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        guard let profiles = self.context.provisioningProfiles else {
            throw OperationError.invalidParameters("RefreshAppOperation.execute: self.context.provisioningProfiles is nil")
        }
        
        guard let appBundle = self.context.targetAppBundle else { throw OperationError(.appNotFound(name: nil)) }
        self.setProgress(10)
        for p in profiles {
            do {
                try await installProvisioningProfiles(p.value.data)
            } catch {
                throw MinimuxerWrapperError.profileInstall
            }
        }
        
        self.setProgress(80)
        guard let dbContext = self.context.dbBackgroundContext else {
            throw OperationError.invalidParameters("RefreshAppOperation: context.dbBackgroundContext is nil")
        }
        
        let installedApp = try await dbContext.perform {
            try self.updateInstalledApp(for: appBundle, profiles: profiles, in: dbContext)
        }
        
        self.setProgress(100)
        return installedApp
    }
    
    private func updateInstalledApp(for appBundle: ALTApplication, profiles: [String: ALTProvisioningProfile], in dbContext: NSManagedObjectContext) throws -> InstalledApp {
        self.setProgress(self.progress.completedUnitCount + 1)
        
        guard let mainApp = self.context.installedApp,
              let installedApp = dbContext.object(with: mainApp.objectID) as? InstalledApp else {
            throw OperationError(.appNotFound(name: appBundle.name))
        }
        guard let mainProfile = profiles[self.context.targetBundleIdentifier] else {
            throw OperationError.invalidParameters("RefreshAppOperation: main provisioning profile is missing")
        }
        installedApp.update(provisioningProfile: mainProfile)
        
        if let certStatus = self.context.targetCertStatus {
            installedApp.certificateStatus = certStatus
        }

        for installedExtension in installedApp.appExtensions {
            guard let provisioningProfile = profiles.values.first(where: {
                $0.bundleIdentifier == installedExtension.resignedBundleIdentifier
            }) else {
                throw OperationError.invalidParameters(
                    "Refresh produced no profile for nested component '\(installedExtension.bundleIdentifier)' (resigned as '\(installedExtension.resignedBundleIdentifier)')."
                )
            }
            installedExtension.update(provisioningProfile: provisioningProfile)
        }
        return installedApp
    }
}
