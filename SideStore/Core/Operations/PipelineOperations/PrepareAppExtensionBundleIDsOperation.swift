//
//  PrepareAppExtensionBundleIDsOperation.swift
//  SideStore
//
//  Created by Magesh K on 01/08/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation

final class PrepareAppExtensionBundleIDsOperation: BasePipelineOperation<AppOperationContext, Void>, @unchecked Sendable {
    override func execute(parentProgress: Progress?) async throws {
        debugLog("[PrepareAppExtensionBundleIDsOperation] execute() started")
        defer { debugLog("[PrepareAppExtensionBundleIDsOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        if let appBundle = self.context.targetAppBundle,
           let profiles = self.context.provisioningProfiles,
           let mainProfile = profiles[self.context.targetBundleIdentifier]
        {
            let originalRootBundleID = appBundle.bundleIdentifier
            let effectiveRootBundleID = self.context.targetBundleIdentifier
            var appexBundleIds: [String: String] = [:]

            for embeddedBundle in appBundle.allEmbeddedApplications {
                let effectiveBundleID: String
                if embeddedBundle.bundleIdentifier == originalRootBundleID {
                    effectiveBundleID = effectiveRootBundleID
                } else if embeddedBundle.bundleIdentifier.hasPrefix(originalRootBundleID + ".") {
                    effectiveBundleID = effectiveRootBundleID + String(embeddedBundle.bundleIdentifier.dropFirst(originalRootBundleID.count))
                } else {
                    effectiveBundleID = embeddedBundle.bundleIdentifier
                }

                if let profile = profiles[effectiveBundleID] {
                    appexBundleIds[effectiveBundleID] = profile.bundleIdentifier
                } else if self.context.useMainProfile && !embeddedBundle.isWatchOSBundle {
                    // Ordinary iOS extensions can share the parent profile.
                    // A watchOS bundle must have an exact profile entry.
                    appexBundleIds[effectiveBundleID] = mainProfile.bundleIdentifier
                }
            }

            self.context.appexBundleIds = appexBundleIds
        }
        self.setProgress(100)
    }
}
