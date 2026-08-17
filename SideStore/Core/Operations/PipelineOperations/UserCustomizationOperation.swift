//
//  UserCustomizationOperation.swift
//  SideStore
//
//  Created by Magesh K on 30/07/26.
//  Copyright © 2026 AltStore. All rights reserved.
//


import Foundation
final class UserCustomizationOperation: BasePipelineOperation<InstallAppOperationContext, String?>, @unchecked Sendable {

    override func execute(parentProgress: Progress?) async throws -> String? {
        debugLog("[UserCustomizationOperation] execute() started")
        defer { debugLog("[UserCustomizationOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)

        guard UserDefaults.standard.customizeAppId else {
            self.setProgress(100)
            return nil
        }

        let handler = context.handler.userCustomizationHandler

        let initialBundleID = context.targetBundleIdentifier
        self.setProgress(40)
        
        guard let customID = try await handler.resolveBundleIDOverride(initialBundleID: initialBundleID) else {
            throw OperationError.cancelled
        }
        
        if customID != context.bundleIdentifier {
            context.customBundleIdentifier = customID
        }
        
        self.setProgress(100)
        return context.targetBundleIdentifier
    }
}
