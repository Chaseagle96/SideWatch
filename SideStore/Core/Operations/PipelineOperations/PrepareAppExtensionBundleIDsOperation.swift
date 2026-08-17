//
//  PrepareAppExtensionBundleIDsOperation.swift
//  SideStore
//
//  Created by Magesh K on 01/08/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation
@preconcurrency import AltSign

final class PrepareAppExtensionBundleIDsOperation: BasePipelineOperation<AppOperationContext, Void>, @unchecked Sendable {
    override func execute(parentProgress: Progress?) async throws {
        debugLog("[PrepareAppExtensionBundleIDsOperation] execute() started")
        defer { debugLog("[PrepareAppExtensionBundleIDsOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        if let appBundle = self.context.targetAppBundle,
           let profiles = self.context.provisioningProfiles,
           profiles[self.context.targetBundleIdentifier] != nil
        {
            let mapping = ALTBundleIdentifierMapping(
                originalRootIdentifier: appBundle.bundleIdentifier,
                mappedRootIdentifier: self.context.targetBundleIdentifier
            )
            var appexBundleIds: [String: String] = [:]

            for embeddedBundle in appBundle.allEmbeddedApplications {
                let effectiveBundleID = mapping.mappedIdentifier(for: embeddedBundle.bundleIdentifier)
                guard let profile = profiles[effectiveBundleID] else {
                    throw OperationError.invalidParameters(
                        "No exact provisioning profile was generated for nested bundle '\(embeddedBundle.bundleIdentifier)' (mapped as '\(effectiveBundleID)')."
                    )
                }
                appexBundleIds[effectiveBundleID] = profile.bundleIdentifier
            }

            self.context.appexBundleIds = appexBundleIds
        }
        self.setProgress(100)
    }
}
