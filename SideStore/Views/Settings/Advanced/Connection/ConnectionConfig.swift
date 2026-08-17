//
//  ConnectionConfig.swift
//  SideStore
//
//  Created by Magesh K on 02/03/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import Combine

final class ConnectionConfig: ObservableObject {
    static let shared = ConnectionConfig()

    private static var defaultOverrideIP: String { AppConstants.Connection.defaultOverrideIP }
    private static var defaultRemoteServerIP: String { AppConstants.Connection.defaultRemoteServerIP }
    private static var defaultWireGuardServerHost: String { AppConstants.Proxy.address }
    private static var defaultWireGuardServerPort: UInt16 { AppConstants.Proxy.defaultPort }

    @Published var tunnelIfaceIp: String?
    @Published var tunnelIfaceSubnetMask: String?
    @Published var tunnelPeerIp: String?
    @Published var tunnelPeerSubnetMask: String?
    @Published var tunnelPeerReachable: Bool = false
    @Published var overrideTunnelPeerIp: String = overrideIPStorage {
        didSet { Self.overrideIPStorage = overrideTunnelPeerIp }
    }
    @Published var overrideTunnelPeerReachable: Bool = false

    @Published var remoteServerIp: String = remoteServerIPStorage {
        didSet { Self.remoteServerIPStorage = remoteServerIp }
    }
    @Published var remotePeerIp: String?
    @Published var remoteReachable: Bool = false

    @Published var useLocalVPN: Bool = useLocalVPNStorage {
        didSet { Self.useLocalVPNStorage = useLocalVPN }
    }

    @Published var wireguardServerHost: String = wireguardServerHostStorage {
        didSet { Self.wireguardServerHostStorage = wireguardServerHost }
    }

    @Published var wireguardServerPort: UInt16 = wireguardServerPortStorage {
        didSet { Self.wireguardServerPortStorage = wireguardServerPort }
    }

    private static var overrideIPStorage: String {
        get { getStoredOverrideIP(default: defaultOverrideIP) }
        set { setStoredOverrideIP(newValue) }
    }

    private static var remoteServerIPStorage: String {
        get { getStoredRemoteServerIP(default: defaultRemoteServerIP) }
        set { setStoredRemoteServerIP(newValue) }
    }

    private static var useLocalVPNStorage: Bool {
        get { UserDefaults.standard.useLocalVPN }
        set { UserDefaults.standard.useLocalVPN = newValue }
    }

    private static var wireguardServerHostStorage: String {
        get { getStoredWireGuardServerHost(default: defaultWireGuardServerHost) }
        set { setStoredWireGuardServerHost(newValue) }
    }

    private static var wireguardServerPortStorage: UInt16 {
        get { getStoredWireGuardServerPort(default: defaultWireGuardServerPort) }
        set { setStoredWireGuardServerPort(newValue) }
    }

    var tunnelPeerActive: ActiveState { tunnelPeerReachable ? .yes : .no }
    var overrideTunnelPeerActive: ActiveState { overrideTunnelPeerReachable ? .yes : .no }
    var remoteActive: ActiveState { remoteReachable ? .yes : .no }

    var formattedTunnelIface: String? {
        guard let ip = tunnelIfaceIp, !ip.isEmpty else { return nil }
        if let mask = tunnelIfaceSubnetMask, let cidr = Self.cidrPrefix(from: mask) {
            return "\(ip)/\(cidr)"
        }
        return ip
    }

    var formattedTunnelPeer: String? {
        guard let ip = tunnelPeerIp, !ip.isEmpty else { return nil }
        if let mask = tunnelPeerSubnetMask, let cidr = Self.cidrPrefix(from: mask) {
            return "\(ip)/\(cidr)"
        }
        return ip
    }

    static func cidrPrefix(from subnetMask: String) -> Int? {
        let octets = subnetMask.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets.reduce(0) { $0 + $1.nonzeroBitCount }
    }
}

// MARK: - Private ConnectionConfig Domain Persistence Extension

private extension ConnectionConfig {
    static func getStoredOverrideIP(default defaultIP: String) -> String {
        return UserDefaults.standard.string(forKey: "TunnelOverridePeerIp") ?? defaultIP
    }
    
    static func setStoredOverrideIP(_ ip: String) {
        UserDefaults.standard.set(ip, forKey: "TunnelOverridePeerIp")
    }
    
    static func getStoredRemoteServerIP(default defaultIP: String) -> String {
        return UserDefaults.standard.string(forKey: "RemoteServerIp") ?? defaultIP
    }
    
    static func setStoredRemoteServerIP(_ ip: String) {
        UserDefaults.standard.set(ip, forKey: "RemoteServerIp")
    }

    static func getStoredWireGuardServerHost(default defaultHost: String) -> String {
        return UserDefaults.standard.string(forKey: "WireGuardServerHost") ?? defaultHost
    }

    static func setStoredWireGuardServerHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: "WireGuardServerHost")
    }

    static func getStoredWireGuardServerPort(default defaultPort: UInt16) -> UInt16 {
        let val = UserDefaults.standard.integer(forKey: "WireGuardServerPort")
        return (val > 0 && val <= 65535) ? UInt16(val) : defaultPort
    }

    static func setStoredWireGuardServerPort(_ port: UInt16) {
        UserDefaults.standard.set(Int(port), forKey: "WireGuardServerPort")
    }
}
