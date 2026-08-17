//
//  SendAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 6/7/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import Network
@preconcurrency import AltSign

final class SendAppOperation: BasePipelineOperation<InstallAppOperationContext, ALTApplication>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> ALTApplication {
        debugLog("[SendAppOperation] execute() started")
        defer { debugLog("[SendAppOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)

        guard let resignedAppBundle = self.context.resignedAppBundle else {
            throw OperationError.invalidParameters("SendAppOperation.main: self.resignedAppBundle is nil")
        }

        let app = AnyApp(name: resignedAppBundle.name, bundleIdentifier: self.context.targetBundleIdentifier, url: resignedAppBundle.fileURL, storeApp: nil)
        let fileURL = InstalledApp.refreshedIPAURL(for: app)
        verboseLog("[SendAppOperation] AFC App `fileURL`: \(fileURL.absoluteString)")

        // Cellular shortcut should only be executed below iOS 16.4 AND when explicitly enabled in settings
        if #available(iOS 16.4, *) {
            context.shouldTurnOffData = false
        } else {
            context.shouldTurnOffData = UserDefaults.standard.isCellularRefreshEnabled
        }
        
        if self.context.shouldTurnOffData {
            // Wait for Shortcut to Finish Before Proceeding
            let shortcutURLoff = URL(string: "shortcuts://run-shortcut?name=TurnOffData")!
            await UIApplication.shared.open(shortcutURLoff)
            self.debugLog("[SendAppOperation] Shortcut finished execution. Proceeding with file transfer.")
        }
        
        try await self.processFile(at: fileURL, for: app.bundleIdentifier)
        return resignedAppBundle
    }

    private func processFile(at fileURL: URL, for bundleIdentifier: String) async throws {
        guard let data = NSData(contentsOf: fileURL) else {
            debugLog("[SendAppOperation] IPA doesn't exist????")
            throw OperationError(.appNotFound(name: bundleIdentifier))
        }
        let bytes = Data(data)
        try await yeetAppAFC(bundleIdentifier, bytes)
        self.setProgress(100)
    }
}
