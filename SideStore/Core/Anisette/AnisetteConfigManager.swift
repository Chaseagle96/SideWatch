//  AnisetteConfigManager.swift
//  SideStore
//
//  Created by Magesh K on 31/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public struct AnisetteConfig: Codable, Equatable {
    public var clientInfo: String
    public var userAgent: String
    public var customDeviceID: String?
    public var customLocalUserID: String?
    public var customLocale: String?
    public var customTimeZone: String?
    public var customXcodeVersion: String?
    
    public init(
        clientInfo: String,
        userAgent: String,
        customDeviceID: String? = nil,
        customLocalUserID: String? = nil,
        customLocale: String? = nil,
        customTimeZone: String? = nil,
        customXcodeVersion: String? = nil
    ) {
        self.clientInfo = clientInfo
        self.userAgent = userAgent
        self.customDeviceID = customDeviceID
        self.customLocalUserID = customLocalUserID
        self.customLocale = customLocale
        self.customTimeZone = customTimeZone
        self.customXcodeVersion = customXcodeVersion
    }
}

public actor AnisetteConfigManager {
    public static let shared = AnisetteConfigManager()
    
    private var configFileURL: URL {
        let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return libraryDirectory.appendingPathComponent("anisette-config.json")
    }
    
    private var serverHeadersFileURL: URL {
        let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return libraryDirectory.appendingPathComponent("anisette-server-headers.json")
    }
    
    public func saveServerHeaders(_ headers: [String: String]) {
        var existing = loadServerHeaders()
        for (key, val) in headers {
            existing[key] = val
        }
        let encoder = Foundation.JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(existing) {
            try? data.write(to: serverHeadersFileURL, options: .atomic)
        }
    }
    
    public func loadServerHeaders() -> [String: String] {
        if let data = try? Data(contentsOf: serverHeadersFileURL),
           let headers = try? Foundation.JSONDecoder().decode([String: String].self, from: data) {
            return headers
        }
        return [:]
    }
    
    public nonisolated var isOfflineMode: Bool {
        get {
            UserDefaults.standard.isAnisetteOfflineMode
        }
        set {
            UserDefaults.standard.isAnisetteOfflineMode = newValue
        }
    }
    
    public func loadConfig() -> AnisetteConfig {
        if let data = try? Data(contentsOf: configFileURL),
           let config = try? Foundation.JSONDecoder().decode(AnisetteConfig.self, from: data) {
            return config
        }
        // Fallback to static defaults in FetchAnisetteDataOperation
        return AnisetteConfig(
            clientInfo: FetchAnisetteDataOperation.defaultClientInfo,
            userAgent: FetchAnisetteDataOperation.defaultUserAgent
        )
    }

    public func resolvedXcodeVersion() async -> String {
        return loadConfig().customXcodeVersion ?? "26.0 (26A242)"
    }
    
    public func saveConfig(_ config: AnisetteConfig) {
        let encoder = Foundation.JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            try? data.write(to: configFileURL, options: .atomic)
        }
    }
    
    public func importFromFile(url: URL) throws -> AnisetteConfig {
        let data = try Data(contentsOf: url)
        
        // Flexible decoding supporting both camelCase and snake_case
        let config: AnisetteConfig
        if let direct = try? Foundation.JSONDecoder().decode(AnisetteConfig.self, from: data) {
            config = direct
        } else {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let json = json else {
                throw NSError(domain: "AnisetteConfigManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON format."])
            }
            
            let clientInfo = (json["clientInfo"] as? String) ?? (json["client_info"] as? String)
            let userAgent = (json["userAgent"] as? String) ?? (json["user_agent"] as? String)
            
            let customDeviceID = (json["customDeviceID"] as? String) ?? (json["custom_device_id"] as? String) ?? (json["deviceUniqueIdentifier"] as? String)
            let customLocalUserID = (json["customLocalUserID"] as? String) ?? (json["custom_local_user_id"] as? String) ?? (json["localUserID"] as? String)
            let customLocale = (json["customLocale"] as? String) ?? (json["custom_locale"] as? String) ?? (json["locale"] as? String)
            let customTimeZone = (json["customTimeZone"] as? String) ?? (json["custom_time_zone"] as? String) ?? (json["timeZone"] as? String)
            
            guard let finalClientInfo = clientInfo, !finalClientInfo.isEmpty,
                  let finalUserAgent = userAgent, !finalUserAgent.isEmpty else {
                throw NSError(domain: "AnisetteConfigManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing or empty required keys (clientInfo, userAgent)."])
            }
            
            config = AnisetteConfig(
                clientInfo: finalClientInfo,
                userAgent: finalUserAgent,
                customDeviceID: customDeviceID,
                customLocalUserID: customLocalUserID,
                customLocale: customLocale,
                customTimeZone: customTimeZone
            )
        }
        
        saveConfig(config)
        return config
    }
    
    public func exportConfigData() -> Data? {
        let config = loadConfig()
        let encoder = Foundation.JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        return try? encoder.encode(config)
    }
    
    public func resetToDefaults() -> AnisetteConfig {
        let config = AnisetteConfig(
            clientInfo: FetchAnisetteDataOperation.defaultClientInfo,
            userAgent: FetchAnisetteDataOperation.defaultUserAgent
        )
        saveConfig(config)
        return config
    }
    
    public func deleteConfigFile() {
        try? FileManager.default.removeItem(at: configFileURL)
    }
    
    public func hasConfigFile() -> Bool {
        return FileManager.default.fileExists(atPath: configFileURL.path)
    }
}
