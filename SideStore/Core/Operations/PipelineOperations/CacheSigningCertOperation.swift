//
//  CacheSigningCertOperation.swift
//  SideStore
//
//  Created by Magesh K on 8/5/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import AltSign

final class CacheSigningCertOperation: BasePipelineOperation<AppOperationContext, Void>, @unchecked Sendable {
    override func execute(parentProgress: Progress?) async throws {
        debugLog("[CacheSigningCertOperation] execute() started")
        defer { debugLog("[CacheSigningCertOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        let bundleID = self.context.targetBundleIdentifier
        if bundleID.isAltStoreAppID {
            debugLog("[CacheSigningCertOperation] Skipping caching of signing cert for self (\(bundleID)) in favor of embedded certificate.")
            return
        }
        
        // 1. Resolve the certificate used for signing this app
        guard let cert = self.context.overrideCertificate ?? self.context.authenticatedContext.signingCertificate else
        {
            throw OperationError.invalidParameters("CacheSigningCertOperation: No signing certificate found in context.")
        }
        
        guard let certData = cert.data else {
            debugLog("[CacheSigningCertOperation] WARNING: Certificate has no data to cache.")
            return
        }
        
        // 2. Resolve target App Group directory
        let appsDirectory = InstalledApp.appsDirectoryURL
        let appDirectory = appsDirectory.appendingPathComponent(bundleID)
        
        do {
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true, attributes: nil)
            let certURL = appDirectory.appendingPathComponent("signing_certificate.der")
            try certData.write(to: certURL, options: .atomic)
            debugLog("[CacheSigningCertOperation] Successfully cached signing certificate to \(certURL.path)")
        } catch {
            debugLog("[CacheSigningCertOperation] ERROR: Failed to write signing certificate to disk: \(error)")
            throw error
        }
    }
}
