//
//  HeartbeatService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
// import RustBridge

final internal class HeartbeatService {
    
    private actor MutableState {
        var running = false
        var taskActive = false

        func tryStart() -> Bool {
            if taskActive {
                running = true
                return false
            }
            running = true
            taskActive = true
            return true
        }

        func stop() {
            running = false
        }

        func terminate() {
            taskActive = false
            running = false
        }
    }

    private static let state = MutableState()
    private static var lastErrorDescription: String?

    static var lastBeatSuccessful = false

    /// Start the heartbeat loop. Safe to call multiple times — ignored if a task is already active.
    static func start() async {
        guard await state.tryStart() else {
            return
        }

        verboseLog("[minimuxer] Starting heartbeat task...")
        Task.detached {
            verboseLog("[minimuxer] heartbeat-task: started")

            await heartbeatLoop()

            await state.terminate()
            lastBeatSuccessful = false
            verboseLog("[minimuxer] heartbeat-task: stopped")
        }
    }

    /// Signal the heartbeat task to stop. The task will exit on next iteration.
    static func stop() async {
        await state.stop()
        lastBeatSuccessful = false
        verboseLog("[minimuxer] HeartbeatService stop requested")
    }

    private static func logIfNeeded(_ message: String, isVerbose: Bool = false) {
        if message != lastErrorDescription {
            if isVerbose {
                verboseLog("[minimuxer] heartbeat-task: \(message)")
            } else {
                debugLog("[minimuxer] heartbeat-task: \(message)")
            }
            lastErrorDescription = message
        }
    }

    private static func heartbeatLoop() async {
        while !MuxerService.shared.isListening {
            logIfNeeded("Waiting for usbmuxd to be ready...", isVerbose: true)
            try? await Task.sleep(nanoseconds: MinimuxerConstants.heartbeatSleepNs)
        }
        verboseLog("[minimuxer] heartbeat-task: usbmuxd is ready")

        var currentInterval: UInt64 = 1000

        while await state.running {
            let tunnelPeerIp: String
            do {
                tunnelPeerIp = try await DeviceEndpoint.shared.ip()
            } catch {
                logIfNeeded("device IP unavailable", isVerbose: true)
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: MinimuxerConstants.heartbeatSleepNs)
                continue
            }
            
            // verify tunnel/device reachability first
            if !Minimuxer.shared.testDeviceConnection(ifaddr: tunnelPeerIp) {
                logIfNeeded("device IP not reachable, waiting...", isVerbose: true)
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: MinimuxerConstants.heartbeatSleepNs)
                continue
            }

            do {
                var newInterval: UInt64 = 0
                try await IdeviceGateway.shared.performHeartbeat(interval: currentInterval, newInterval: &newInterval)
                currentInterval = newInterval > 0 ? newInterval : 1000
                lastBeatSuccessful = true
                lastErrorDescription = nil
            } catch {
                logIfNeeded("Heartbeat failed: \(error)")
                lastBeatSuccessful = false
                try? await Task.sleep(nanoseconds: MinimuxerConstants.heartbeatSleepNs)
            }
        }
    }
}
