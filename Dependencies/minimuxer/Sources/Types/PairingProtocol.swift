//
//  PairingProtocol.swift
//  Minimuxer
//
//  Created by Magesh K on 7/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

public enum PairingProtocol: String, Codable, CustomStringConvertible, Sendable {
    case rppairing = "rppairing"
    case lockdown = "lockdown"
    case unknown = "unknown"
    
    public var description: String {
        return self.rawValue
    }
}
