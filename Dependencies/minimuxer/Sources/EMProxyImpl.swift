//
//  EMProxyImpl.swift
//  Minimuxer
//
//  Created by Magesh K on 12/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import EMProxy
import Network


public enum EMProxyError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    case invalidBindAddressPointer
    case invalidUTF8String
    case invalidSocketAddress(String)
    case socketBindFailed
    case cryptoInitFailed
    case serverNotRunning
    case stopSignalFailed
    case threadJoinFailed
    case handshakeClientNotConfigured
    case unknownError(Int32)

    public var description: String {
        switch self {
        case .invalidBindAddressPointer:
            return "Invalid bind address pointer"
        case .invalidUTF8String:
            return "Failed to convert bind address to UTF-8"
        case .invalidSocketAddress(let addr):
            return "Invalid IPv4 socket address format: \(addr)"
        case .socketBindFailed:
            return "Failed to bind to UDP socket address"
        case .cryptoInitFailed:
            return "Failed to initialize EMProxy crypto keys"
        case .serverNotRunning:
            return "EMProxy server is not running"
        case .stopSignalFailed:
            return "Failed to send stop signal to EMProxy server"
        case .threadJoinFailed:
            return "Failed to join EMProxy loopback thread"
        case .handshakeClientNotConfigured:
            return "EMProxy WireGuard VPN handshake client not configured"
        case .unknownError(let code):
            return "EMProxy error code: \(code)"
        }
    }

    public var errorDescription: String? {
        return description
    }
}

public final class EMProxyImpl: @unchecked Sendable, EMProxyAPI {
    private struct HandshakeConfig: Sendable {
        let host: String
        let port: UInt16
        let enabled: Bool
    }
    private var handshakeConfig: HandshakeConfig?
    private let handshakeLock = NSLock()

    public func setHandshakeClient(host: String, port: UInt16, enabled: Bool) {
        handshakeLock.withLock {
            self.handshakeConfig = HandshakeConfig(host: host, port: port, enabled: enabled)
        }
    }

    public init() {
        set_log_callback { level, msgPtr in
            guard let msgPtr = msgPtr else { return false }
            let msg = "[EMProxy] \(String(cString: msgPtr))"
            if level <= 1 {
                verboseLog(msg)
            } else {
                debugLog(msg)
            }
            return true
        }
    }



    public func start(host: String, port: UInt16) async throws {
        let config = handshakeLock.withLock { self.handshakeConfig }
        guard let config = config else {
            throw EMProxyError.handshakeClientNotConfigured
        }
        let address = "\(host):\(port)"
        try await matchingPriority {
            try await withFFIDispatch {
                switch start_emotional_damage(address) {
                    case 0:
                        break
                    case -1:
                        throw EMProxyError.invalidBindAddressPointer
                    case -2:
                        throw EMProxyError.invalidUTF8String
                    case -3:
                        throw EMProxyError.invalidSocketAddress(address)
                    case -4:
                        throw EMProxyError.socketBindFailed
                    case -5:
                        throw EMProxyError.cryptoInitFailed
                    case let err:
                        throw EMProxyError.unknownError(err)
                }
            }
        }
        if config.enabled {
            await triggerVPNHandshake(host: config.host, port: config.port)
        }
    }

    public func stop() async throws {
        try await matchingPriority {
            try await withFFIDispatch {
                switch stop_emotional_damage() {
                    case 0:
                        return
                    case -1:
                        throw EMProxyError.serverNotRunning
                    case -2:
                        throw EMProxyError.stopSignalFailed
                    case -3:
                        throw EMProxyError.threadJoinFailed
                    case let err:
                        throw EMProxyError.unknownError(err)
                }
            }
        }
    }



    private func triggerVPNHandshake(host: String, port: UInt16) async {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debugLog("[EMProxy] triggerVPNHandshake skipped: host is empty")
            return
        }
        let timeout = Double(MinimuxerConstants.vpnHandshakeTimeoutNs) / 1_000_000_000.0
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            
            let success = await withCheckedContinuation { continuation in
                var resolved = false
                let lock = NSLock()
                
                let resolve = { (result: Bool) in
                    lock.withLock {
                        if !resolved {
                            resolved = true
                            continuation.resume(returning: result)
                        }
                    }
                }
                
                connection.stateUpdateHandler = { state in
                    debugLog("[EMProxy] triggerVPNHandshake state: \(state)")
                    if let result = self.isProbeSuccessful(for: state) {
                        resolve(result)
                    }
                }
                connection.start(queue: .global())
                
                // Limit this probe attempt to 1 second
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    resolve(false)
                    connection.cancel()
                }
            }
            
            connection.cancel()
            
            if success {
                return // Tunnel is ready!
            }
            
            // Wait 200ms before starting the next probe
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func isProbeSuccessful(for state: NWConnection.State) -> Bool? {
        switch state {
            case .ready:
                return true
            case .failed, .cancelled:
                return false
            case .waiting(let error):
                // POSIX error 61 is "Connection refused".
                // This means the tunnel is fully working and routed, but nothing is listening on that port yet.
                let isRefused = (error as NSError).code == 61
                if isRefused {
                    return true
                }
                return nil
            default:
                return nil
        }
    }
}
