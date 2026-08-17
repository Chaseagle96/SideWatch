//
//  UpdateAppCertificateOperation.swift
//  SideStore
//
//  Created by Magesh K on 1/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import CoreData
@preconcurrency import AltSign

final class UpdateAppCertificateOperation: BasePipelineOperation<InstallAppOperationContext, Void>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws {
        debugLog("[UpdateAppCertificateOperation] execute() started")
        defer { debugLog("[UpdateAppCertificateOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        if let installedApp = self.context.installedApp, let serialNumber = installedApp.certificateSerialNumber {
            debugLog("[UpdateAppCertificateOperation] InstalledApp '\(installedApp.name)' has custom certificate serial: '\(serialNumber)'")
            if let customCert = CertificateManager.shared.getSignableCertificate(for: serialNumber) {
                debugLog("[UpdateAppCertificateOperation] Loaded custom certificate '\(customCert.serialNumber)' for app '\(installedApp.name)'. Setting context.overrideCertificate.")
                self.context.overrideCertificate = customCert
            } else {
                debugLog("[UpdateAppCertificateOperation] WARNING: Signable certificate with serial '\(serialNumber)' not found for app '\(installedApp.name)'.")
            }
        }
        
        self.setProgress(100)
    }
}
