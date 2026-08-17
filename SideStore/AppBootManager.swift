//
//  AppBootManager.swift
//  SideStore
//
//  Created by Magesh K on 9/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public final class AppBootManager {
    public static let shared = AppBootManager()
    
    private let lock = NSLock()
    
    private var _needsPairingPrompt = false
    public var needsPairingPrompt: Bool {
        get { lock.withLock { _needsPairingPrompt } }
        set { lock.withLock { _needsPairingPrompt = newValue } }
    }
    
    private var _needsSideJITPrompt = false
    public var needsSideJITPrompt: Bool {
        get { lock.withLock { _needsSideJITPrompt } }
        set { lock.withLock { _needsSideJITPrompt = newValue } }
    }
    
    private init() {}
    

    public nonisolated func startMinimuxer(pairingFile: String) async throws {
        debugLog("[AppBootManager] startMinimuxer() entered")
        defer { debugLog("[AppBootManager] startMinimuxer() exited") }
        
        if UserDefaults.standard.enableEMPforWireguard {
            debugLog("[AppBootManager] Starting EMProxy before minimuxer...")
            try await startEMProxy()
        }

        try await minimuxerStart(pairingFile, mountPath: FileManager.default.documentsDirectory.absoluteString)
        
        // Validate the pairing by trying to fetch the UDID
        do {
            debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection starting...")
            let deviceUDID = try await fetchUDID()
            debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test SUCCEEDED. UDID: \(deviceUDID ?? "nil")")
            self.needsPairingPrompt = false
        } catch {
            if error.isMinimuxerPairingFile {
                debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test FAILED. \(error)")
                self.needsPairingPrompt = true
                throw error
            } else {
                debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test FAILED but PAIRING FILE IS VALID. \(error)")
            }
        }
    }
    
    public nonisolated func performBootSequence() async {
        debugLog("[AppBootManager] performBootSequence() entered")
        defer {
            debugLog("[AppBootManager] performBootSequence() exited")
        }
        // 1. Structured concurrent child task A
        async let jitCheck: Void = {
            debugLog("[AppBootManager] performBootSequence(): JIT check starting")
            defer {
                debugLog("[AppBootManager] performBootSequence(): JIT check completed")
            }
            if #available(iOS 17, *), !UserDefaults.standard.sidejitenable {
                do {
                    try await SideJITManager.shared.isSideJITServerDetected()
                    self.needsSideJITPrompt = true
                } catch {
                    debugLog("[AppBootManager] Cannot find sideJITServer")
                }
            }
            
            if #available(iOS 17, *), UserDefaults.standard.sidejitenable {
                await SideJITManager.shared.askForNetwork()
                debugLog("[AppBootManager] SideJITServer Enabled")
            }
        }()
        
        // 2. Structured concurrent child task B
        async let minimuxerCheck: Void = {
            debugLog("[AppBootManager] performBootSequence(): Minimuxer check starting")
            defer {
                debugLog("[AppBootManager] performBootSequence(): Minimuxer check completed")
            }
            #if targetEnvironment(simulator)
            do {
                try await self.startMinimuxer(pairingFile: "ignored-for-sim")
            } catch {
                debugLog("[AppBootManager] Failed to start minimuxer: \(error)")
            }
            #else
            if let pf = PairingFileManager.shared.fetchPairingFile() {
                do {
                    try await self.startMinimuxer(pairingFile: pf)
                } catch {
                    debugLog("[AppBootManager] Failed to start minimuxer: \(error)")
                }
            } else {
                self.needsPairingPrompt = true
            }
            #endif
        }()
        
        // Await both concurrently (Structured Concurrency awaits them in parallel)
        _ = await (jitCheck, minimuxerCheck)
    }
}
