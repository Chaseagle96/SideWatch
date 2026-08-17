//
//  FetchAnisetteDataOperation.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//


import Foundation
import CommonCrypto
import Starscream
@preconcurrency import AltSign

final class FetchAnisetteDataOperation: BaseStandaloneOperation<AuthenticatedOperationContext, ALTAnisetteData>, @unchecked Sendable {
    public static let defaultClientInfo = "<MacBookPro18,3> <macOS;26.6;25F84> <com.apple.AuthKit/1 (com.apple.dt.Xcode/26.0)>"
    public static let defaultUserAgent = "AuthKit/1 (Macintosh; OS X 26.6) (com.apple.dt.Xcode/26.0)"

    var url: URL?
    var startProvisioningURL: URL?
    var endProvisioningURL: URL?
    
    var clientInfo: String?
    var userAgent: String?
    var activeConfig: AnisetteConfig?
    
    var mdLu: String?
    var deviceId: String?
    
    var resolvedClientInfo: String {
        self.activeConfig?.clientInfo ?? self.clientInfo ?? FetchAnisetteDataOperation.defaultClientInfo
    }
    
    var resolvedUserAgent: String {
        self.activeConfig?.userAgent ?? self.userAgent ?? FetchAnisetteDataOperation.defaultUserAgent
    }
    
    var resolvedDeviceID: String {
        if let custom = self.activeConfig?.customDeviceID, !custom.isEmpty {
            return custom
        }
        return self.deviceId ?? ""
    }
    
    var resolvedLocalUserID: String {
        if let custom = self.activeConfig?.customLocalUserID, !custom.isEmpty {
            return custom
        }
        return self.mdLu ?? ""
    }
    
    var resolvedLocale: String {
        if let custom = self.activeConfig?.customLocale, !custom.isEmpty {
            return custom
        }
        return Locale.current.identifier
    }
    
    var resolvedTimeZone: String {
        if let custom = self.activeConfig?.customTimeZone, !custom.isEmpty {
            return custom
        }
        return TimeZone.current.abbreviation() ?? "UTC"
    }
    
    override func execute(parentProgress: Progress?) async throws -> ALTAnisetteData {
        debugLog("[FetchAnisetteDataOperation] execute() started")
        defer { debugLog("[FetchAnisetteDataOperation] execute() completed") }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)
        
        if let authContext = self.context,
           let session = authContext.session,
           session.anisetteData.date.timeIntervalSinceNow > -30.0 {
            self.debugLog("[FetchAnisetteDataOperation] Skipping anisette fetch: Anisette data is still fresh (\(-session.anisetteData.date.timeIntervalSinceNow)s old).")
            self.setProgress(100)
            return session.anisetteData
        }
        
        self.setProgress(20)
        let result = try await self.startProvisioningFlow()
        self.setProgress(100)
        return result
    }

    private func startProvisioningFlow() async throws -> ALTAnisetteData {
        let config = await AnisetteConfigManager.shared.loadConfig()
        self.activeConfig = config
        
        let isOffline = AnisetteConfigManager.shared.isOfflineMode
        var excludedURLs = Set<String>()
        
        while true {
            do {
                return try await self.performProvisioning(excluding: excludedURLs)
            } catch {
                self.debugLog("[FetchAnisetteDataOperation] Provisioning flow failed: \(error). Checking recovery/retry options...")
                
                if isOffline {
                    self.debugLog("[FetchAnisetteDataOperation] Recovery: Deleting local config and retrying online.")
                    await AnisetteConfigManager.shared.deleteConfigFile()
                    
                    // Clear state properties so performProvisioning will fetch fresh data from server
                    self.clientInfo = nil
                    self.userAgent = nil
                    
                    do {
                        return try await self.performProvisioning(excluding: excludedURLs)
                    } catch {
                        self.debugLog("[FetchAnisetteDataOperation] Recovery attempt failed: \(error)")
                        throw error
                    }
                }
                
                if let failedURLString = self.url?.absoluteString, !UserDefaults.standard.disableAnisetteRotation {
                    excludedURLs.insert(failedURLString)
                    self.debugLog("[FetchAnisetteDataOperation] Server \(failedURLString) failed to provision. Rotating and retrying...")
                    continue
                }
                
                throw error
            }
        }
    }

    private func performProvisioning(excluding: Set<String> = []) async throws -> ALTAnisetteData {
        self.url = nil
        let config = await AnisetteConfigManager.shared.loadConfig()
        self.activeConfig = config
        
        let isOffline = AnisetteConfigManager.shared.isOfflineMode
        if isOffline {
            self.clientInfo = config.clientInfo
            self.userAgent = config.userAgent
            self.verboseLog("[FetchAnisetteDataOperation] Running in OFFLINE config mode. clientInfo: \(self.clientInfo!), userAgent: \(self.userAgent!)")
        } else {
            if self.clientInfo == nil {
                self.clientInfo = FetchAnisetteDataOperation.defaultClientInfo
            }
            if self.userAgent == nil {
                self.userAgent = FetchAnisetteDataOperation.defaultUserAgent
            }
        }
        
        if let error = self.context.error {
            throw error
        }
        
        self.setProgress(30)
        let urlString = try await self.getAnisetteServerUrl(excluding: excluding)

        // set as preferred
        UserDefaults.standard.menuAnisetteURL = urlString
        let url = URL(string: urlString)
        self.url = url
        self.setProgress(60)
        self.verboseLog("[FetchAnisetteDataOperation] Anisette URL: \(self.url!.absoluteString)")

        if let identifier = AnisetteDataManager.shared.anisetteIdentifier,
           let adiPb = AnisetteDataManager.shared.anisetteAdiBlob {
            return try await self.fetchAnisetteV3(identifier, adiPb)
        } else {
            return try await self.provision()
        }
    }

    private func getAnisetteServerUrl(excluding: Set<String> = []) async throws -> String {
        let serverUrls = await AnisetteServersManager.shared.getActiveServerURLs()
        let filteredUrls = serverUrls.filter { !excluding.contains($0) }
        guard !filteredUrls.isEmpty else {
            throw NSError(domain: "AnisetteError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No working anisette servers found."])
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        
        if UserDefaults.standard.disableAnisetteRotation {
            let activeServer = excluding.contains(lastServer) ? (filteredUrls.first ?? lastServer) : lastServer
            self.verboseLog("[FetchAnisetteDataOperation] Auto-rotation disabled. Pinging currently active server: \(activeServer)")
            guard let url = URL(string: activeServer) else {
                throw NSError(domain: "AnisetteError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Active server URL is invalid: \(activeServer)"])
            }
            let success = try await pingServer(url)
            if success {
                return activeServer
            } else {
                throw NSError(domain: "AnisetteError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Active server is offline: \(activeServer)"])
            }
        }
        
        let startIndex = filteredUrls.firstIndex(of: lastServer) ?? 0
        
        for triedCount in 0..<filteredUrls.count {
            let currentIndex = (startIndex + triedCount) % filteredUrls.count
            let currentServerUrlString = filteredUrls[currentIndex]

            guard let url = URL(string: currentServerUrlString) else {
                let errmsg = "[FetchAnisetteDataOperation] Skipping invalid URL: \(currentServerUrlString)"
                self.verboseLog(errmsg)
                continue
            }

            do {
                let success = try await pingServer(url)
                if success {
                    let okmsg = "[FetchAnisetteDataOperation] Found working server: \(url.absoluteString)"
                    self.verboseLog(okmsg)
                    return currentServerUrlString
                } else {
                    let errmsg = "[FetchAnisetteDataOperation] Server ping failed: \(url.absoluteString)"
                    self.verboseLog(errmsg)
                }
            } catch {
                let errmsg = "[FetchAnisetteDataOperation] Server connection failed: \(url.absoluteString) with error: \(error.localizedDescription)"
                self.verboseLog(errmsg)
            }
        }

        throw NSError(domain: "AnisetteError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No working anisette servers found."])
    }

    private func pingServer(_ url: URL) async throws -> Bool {
        // Try pinging the V3 API client_info endpoint first to verify backend handler is active
        let v3URL = url.appendingPathComponent("v3").appendingPathComponent("client_info")
        var request = URLRequest(url: v3URL)
        request.timeoutInterval = 3
        request.httpMethod = "GET"
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return true
            }
        } catch {
            // Ignore error and fall back to root ping
        }
        
        // Fall back to pinging root URL (e.g. for V1 servers or custom configurations)
        var rootRequest = URLRequest(url: url)
        rootRequest.timeoutInterval = 3
        rootRequest.httpMethod = "GET"
        
        let (_, response) = try await URLSession.shared.data(for: rootRequest)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            return true
        }
        return false
    }
    
    // MARK: - COMMON
    func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) async throws -> ALTAnisetteData {
        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
            if v3 {
                if json["result"] == "GetHeadersError" {
                    let message = json["message"]
                    self.verboseLog("[FetchAnisetteDataOperation] Error getting V3 headers: \(message ?? "no message")")
                    if let message = message,
                       message.contains("-45061") {
                        self.verboseLog("[FetchAnisetteDataOperation] Error message contains -45061 (not provisioned), resetting adi.pb and retrying")
                        AnisetteDataManager.shared.anisetteAdiBlob = nil
                        return try await self.provision()
                    } else { throw OperationError.anisetteV3Error(message: message ?? "Unknown error") }
                }
            }
            
            await AnisetteConfigManager.shared.saveServerHeaders(json)
            
            var formattedJSON: [String: String] = ["deviceSerialNumber": "0"]
            if let machineID = json["X-Apple-I-MD-M"] { formattedJSON["machineID"] = machineID }
            if let oneTimePassword = json["X-Apple-I-MD"] { formattedJSON["oneTimePassword"] = oneTimePassword }
            if let routingInfo = json["X-Apple-I-MD-RINFO"] { formattedJSON["routingInfo"] = routingInfo }
            
            if v3 {
                formattedJSON["deviceDescription"] = self.resolvedClientInfo
                formattedJSON["localUserID"] = self.resolvedLocalUserID
                formattedJSON["deviceUniqueIdentifier"] = self.resolvedDeviceID
                
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone.init(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
                let dateString = formatter.string(from: Date())
                formattedJSON["date"] = dateString
                formattedJSON["locale"] = self.resolvedLocale
                formattedJSON["timeZone"] = self.resolvedTimeZone
            } else {
                if let deviceDescription = json["X-MMe-Client-Info"] { formattedJSON["deviceDescription"] = deviceDescription }
                if let localUserID = json["X-Apple-I-MD-LU"] { formattedJSON["localUserID"] = localUserID }
                if let deviceUniqueIdentifier = json["X-Mme-Device-Id"] { formattedJSON["deviceUniqueIdentifier"] = deviceUniqueIdentifier }
                
                if let date = json["X-Apple-I-Client-Time"] { formattedJSON["date"] = date }
                if let locale = json["X-Apple-Locale"] { formattedJSON["locale"] = locale }
                if let timeZone = json["X-Apple-I-TimeZone"] { formattedJSON["timeZone"] = timeZone }
            }
            
            if let response = response,
               let version = response.value(forHTTPHeaderField: "Implementation-Version") {
                self.verboseLog("[FetchAnisetteDataOperation] Implementation-Version: \(version)")
            } else { self.verboseLog("[FetchAnisetteDataOperation] No Implementation-Version header") }
            
            self.verboseLog("[FetchAnisetteDataOperation] Anisette used: \(formattedJSON)")
            self.verboseLog("[FetchAnisetteDataOperation] Original JSON: \(json)")
            if let anisette = ALTAnisetteData(json: formattedJSON) {
                self.debugLog("[FetchAnisetteDataOperation] Anisette is valid!")
                return anisette
            } else {
                self.debugLog("[FetchAnisetteDataOperation] Anisette is invalid!!!!")
                if v3 {
                    throw OperationError.anisetteV3Error(message: "Invalid anisette (the returned data may not have all the required fields)")
                } else {
                    throw OperationError.anisetteV1Error(message: "Invalid anisette (the returned data may not have all the required fields)")
                }
            }
        } else {
            if v3 {
                throw OperationError.anisetteV3Error(message: "Invalid anisette (the returned data may not be in JSON)")
            } else {
                throw OperationError.anisetteV1Error(message: "Invalid anisette (the returned data may not be in JSON)")
            }
        }
    }
    
    // MARK: - V1
    private func handleV1() async throws -> ALTAnisetteData {
        self.verboseLog("[FetchAnisetteDataOperation] Server is V1")
        
        if UserDefaults.standard.defaultServerURL == AnisetteManager.currentURLString {
            self.verboseLog("[FetchAnisetteDataOperation] Server has already been set, fetching anisette")
            return try await self.fetchAnisetteV1()
        }
        
        self.debugLog("[FetchAnisetteDataOperation] Alerting user about outdated server")
        
        let handler = self.context.anisetteServerHandler
        
        let shouldContinue = try await handler.warnOutdatedAnisetteServer()
        if shouldContinue {
            self.verboseLog("[FetchAnisetteDataOperation] Fetching anisette via V1")
            UserDefaults.standard.defaultServerURL = AnisetteManager.currentURLString
            return try await self.fetchAnisetteV1()
        } else {
            self.debugLog("[FetchAnisetteDataOperation] Cancelled anisette operation")
            throw OperationError.cancelled
        }
    }
    
    private func fetchAnisetteV1() async throws -> ALTAnisetteData {
        self.verboseLog("[FetchAnisetteDataOperation] Fetching anisette V1")
        let (data, response) = try await URLSession.shared.data(from: self.url!)
        return try await self.extractAnisetteData(data, response as? HTTPURLResponse, v3: false)
    }
    
    // MARK: - V3: PROVISIONING
    
    private func provision() async throws -> ALTAnisetteData {
        try await fetchClientInfo()
        self.verboseLog("[FetchAnisetteDataOperation] Getting provisioning URLs")
        var request = self.buildAppleRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!)
        request.httpMethod = "GET"
        
        let (data, _) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let startProvisioningString = plist["urls"]?["midStartProvisioning"] as? String,
           let startProvisioningURL = URL(string: startProvisioningString),
           let endProvisioningString = plist["urls"]?["midFinishProvisioning"] as? String,
           let endProvisioningURL = URL(string: endProvisioningString) {
            self.startProvisioningURL = startProvisioningURL
            self.endProvisioningURL = endProvisioningURL
            self.verboseLog("[FetchAnisetteDataOperation] startProvisioningURL: \(self.startProvisioningURL!.absoluteString)")
            self.verboseLog("[FetchAnisetteDataOperation] endProvisioningURL: \(self.endProvisioningURL!.absoluteString)")
            self.verboseLog("[FetchAnisetteDataOperation] Starting a provisioning session")
            
            let session = AnisetteWebSocketSession(
                url: self.url!,
                startProvisioningURL: self.startProvisioningURL!,
                endProvisioningURL: self.endProvisioningURL!,
                clientInfo: self.resolvedClientInfo,
                userAgent: self.resolvedUserAgent,
                mdLu: self.resolvedLocalUserID,
                deviceId: self.resolvedDeviceID,
                parentOperation: self
            )
            return try await session.start()
        } else {
            self.debugLog("[FetchAnisetteDataOperation] Apple didn't give valid URLs! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
            throw OperationError.provisioningError(result: "Apple didn't give valid URLs. Please try again later", message: nil)
        }
    }
    
    func buildAppleRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(self.resolvedClientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(self.resolvedUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        request.setValue(self.resolvedLocalUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(self.resolvedDeviceID, forHTTPHeaderField: "X-Mme-Device-Id")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let dateString = formatter.string(from: Date())
        request.setValue(dateString, forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(self.resolvedLocale, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(self.resolvedTimeZone, forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }
    
    // MARK: - V3: FETCHING
    
    private func fetchClientInfo() async throws {
        let isOffline = AnisetteConfigManager.shared.isOfflineMode
        if isOffline {
            let config = await AnisetteConfigManager.shared.loadConfig()
            self.clientInfo = config.clientInfo
            self.userAgent = config.userAgent
            self.verboseLog("[FetchAnisetteDataOperation] Offline mode enabled. Skipping server client_info fetch.")
        }
        
        if self.clientInfo != nil &&
           self.userAgent != nil &&
           self.mdLu != nil &&
           self.deviceId != nil &&
           AnisetteDataManager.shared.anisetteIdentifier != nil {
            self.verboseLog("[FetchAnisetteDataOperation] Skipping client_info fetch since all the properties we need aren't nil")
            return
        }
        self.verboseLog("[FetchAnisetteDataOperation] Trying to get client_info")
        let clientInfoURL = self.url!.appendingPathComponent("v3").appendingPathComponent("client_info")
        var request = URLRequest(url: clientInfoURL)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        
        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
            if let clientInfo = json["client_info"] {
                self.verboseLog("[FetchAnisetteDataOperation] Server is V3")
                
                await AnisetteConfigManager.shared.saveServerHeaders(json)
                
                self.verboseLog("[FetchAnisetteDataOperation] Overriding server Client-Info '\(clientInfo)' and User-Agent '\(json["user_agent"] ?? "")' with defaults")
                self.clientInfo = FetchAnisetteDataOperation.defaultClientInfo
                self.userAgent = FetchAnisetteDataOperation.defaultUserAgent
                self.verboseLog("[FetchAnisetteDataOperation] Client-Info: \(self.clientInfo!)")
                self.verboseLog("[FetchAnisetteDataOperation] User-Agent: \(self.userAgent!)")
                
                let config = AnisetteConfig(clientInfo: self.clientInfo!, userAgent: self.userAgent!)
                await AnisetteConfigManager.shared.saveConfig(config)
                
                if AnisetteDataManager.shared.anisetteIdentifier == nil {
                    self.verboseLog("[FetchAnisetteDataOperation] Generating identifier")
                    var bytes = [Int8](repeating: 0, count: 16)
                    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                    
                    if status != errSecSuccess {
                        self.debugLog("[FetchAnisetteDataOperation] ERROR GENERATING IDENTIFIER!!! \(status)")
                        throw OperationError.provisioningError(result: "Couldn't generate identifier", message: nil)
                    }
                    
                    AnisetteDataManager.shared.anisetteIdentifier = Data(bytes: &bytes, count: bytes.count).base64EncodedString()
                }
                
                let decoded = Data(base64Encoded: AnisetteDataManager.shared.anisetteIdentifier!)!
                self.mdLu = decoded.sha256().hexEncodedString()
                self.verboseLog("[FetchAnisetteDataOperation] X-Apple-I-MD-LU: \(self.mdLu!)")
                let uuid: UUID = decoded.object()
                self.deviceId = uuid.uuidString.uppercased()
                self.verboseLog("[FetchAnisetteDataOperation] X-Mme-Device-Id: \(self.deviceId!)")
            } else {
                _ = try await self.handleV1()
            }
        } else {
            throw OperationError.anisetteV3Error(message: "Couldn't fetch client info. The returned data may not be in JSON")
        }
    }
    
    func fetchAnisetteV3(_ identifier: String, _ adiPb: String) async throws -> ALTAnisetteData {
        try await self.fetchClientInfo()
        self.verboseLog("[FetchAnisetteDataOperation] Fetching anisette V3")
        guard let serverURL = self.url else {
            throw OperationError.anisetteV3Error(message: "Anisette server URL is not configured.")
        }
        var request = URLRequest(url: serverURL.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.httpBody = try! JSONSerialization.data(withJSONObject: [
            "identifier": identifier,
            "adi_pb": adiPb
        ], options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try await self.extractAnisetteData(data, response as? HTTPURLResponse, v3: true)
    }
}

private class AnisetteWebSocketSession: WebSocketDelegate {
    private let url: URL
    private let startProvisioningURL: URL
    private let endProvisioningURL: URL
    
    private let clientInfo: String
    private let userAgent: String
    private let mdLu: String
    private let deviceId: String
    
    private let parentOperation: FetchAnisetteDataOperation
    private var continuation: SafeContinuation<ALTAnisetteData, Error>?
    
    private var socket: WebSocket!
    
    init(url: URL, startProvisioningURL: URL, endProvisioningURL: URL, clientInfo: String, userAgent: String, mdLu: String, deviceId: String, parentOperation: FetchAnisetteDataOperation) {
        self.url = url
        self.startProvisioningURL = startProvisioningURL
        self.endProvisioningURL = endProvisioningURL
        self.clientInfo = clientInfo
        self.userAgent = userAgent
        self.mdLu = mdLu
        self.deviceId = deviceId
        self.parentOperation = parentOperation
    }
    
    func start() async throws -> ALTAnisetteData {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = SafeContinuation(continuation)
            
            let provisioningSessionURL = self.url.appendingPathComponent("v3").appendingPathComponent("provisioning_session")
            var wsRequest = URLRequest(url: provisioningSessionURL)
            wsRequest.timeoutInterval = 5
            self.socket = WebSocket(request: wsRequest)
            self.socket.delegate = self
            self.socket.connect()
        }
    }
    
    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .text(let string):
            self.handleTextEvent(string, client: client)
            
        case .connected:
            parentOperation.debugLog("[FetchAnisetteDataOperation] Connected")
            
        case .disconnected(let string, let code):
            parentOperation.debugLog("[FetchAnisetteDataOperation] Disconnected: \(code); \(string)")
            self.continuation?.resume(throwing: OperationError.provisioningError(result: "WebSocket disconnected: \(string) (code: \(code))", message: nil))
            
        case .error(let error):
            parentOperation.debugLog("[FetchAnisetteDataOperation] Got error: \(String(describing: error))")
            if let error = error {
                self.continuation?.resume(throwing: error)
            } else {
                self.continuation?.resume(throwing: OperationError.provisioningError(result: "WebSocket error", message: nil))
            }
            
        case .peerClosed:
            parentOperation.debugLog("[FetchAnisetteDataOperation] Peer closed connection")
            self.continuation?.resume(throwing: OperationError.provisioningError(result: "Peer closed connection", message: nil))
            
        case .cancelled:
            parentOperation.debugLog("[FetchAnisetteDataOperation] Connection cancelled")
            self.continuation?.resume(throwing: OperationError.provisioningError(result: "WebSocket connection cancelled", message: nil))
            
        default:
            parentOperation.debugLog("[FetchAnisetteDataOperation] Unknown event: \(event)")
        }
    }
    
    private func handleTextEvent(_ string: String, client: WebSocketClient) {
        do {
            if let json = try JSONSerialization.jsonObject(with: string.data(using: .utf8)!, options: []) as? [String: Any] {
                guard let result = json["result"] as? String else {
                    parentOperation.debugLog("[FetchAnisetteDataOperation] The server didn't give us a result")
                    client.disconnect(closeCode: 0)
                    self.continuation?.resume(throwing: OperationError.provisioningError(result: "The server didn't give us a result", message: nil))
                    return
                }
                parentOperation.verboseLog("[FetchAnisetteDataOperation] Received result: \(result)")
                switch result {
                case "GiveIdentifier":
                    parentOperation.verboseLog("[FetchAnisetteDataOperation] Giving identifier")
                    client.json(["identifier": AnisetteDataManager.shared.anisetteIdentifier!])
                    
                case "GiveStartProvisioningData":
                    self.handleGiveStartProvisioningData(client: client)
                    
                case "GiveEndProvisioningData":
                    self.handleGiveEndProvisioningData(json: json, client: client)
                    
                case "ProvisioningSuccess":
                    self.handleProvisioningSuccess(json: json, client: client)
                    
                default:
                    if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                        parentOperation.debugLog("[FetchAnisetteDataOperation] Failing because of \(result)")
                        self.continuation?.resume(throwing: OperationError.provisioningError(result: result, message: json["message"] as? String))
                    }
                }
            }
        } catch let error as NSError {
            parentOperation.debugLog("[FetchAnisetteDataOperation] Failed to handle text: \(error.localizedDescription)")
            self.continuation?.resume(throwing: OperationError.provisioningError(result: error.localizedDescription, message: nil))
        }
    }
    
    private func handleGiveStartProvisioningData(client: WebSocketClient) {
        parentOperation.verboseLog("[FetchAnisetteDataOperation] Getting start provisioning data")
        let body = [
            "Header": [String: Any](),
            "Request": [String: Any](),
        ]
        var request = parentOperation.buildAppleRequest(url: self.startProvisioningURL)
        request.httpMethod = "POST"
        request.httpBody = try! PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
                   let spim = plist["Response"]?["spim"] as? String {
                    parentOperation.verboseLog("[FetchAnisetteDataOperation] Giving start provisioning data")
                    client.json(["spim": spim])
                } else {
                    parentOperation.debugLog("[FetchAnisetteDataOperation] Apple didn't give valid start provisioning data! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
                    client.disconnect(closeCode: 0)
                    self.continuation?.resume(throwing: OperationError.provisioningError(result: "Apple didn't give valid start provisioning data. Please try again later", message: nil))
                }
            } catch {
                client.disconnect(closeCode: 0)
                self.continuation?.resume(throwing: error)
            }
        }
    }
    
    private func handleGiveEndProvisioningData(json: [String: Any], client: WebSocketClient) {
        parentOperation.verboseLog("[FetchAnisetteDataOperation] Getting end provisioning data")
        guard let cpim = json["cpim"] as? String else {
            parentOperation.debugLog("[FetchAnisetteDataOperation] The server didn't give us a cpim")
            client.disconnect(closeCode: 0)
            self.continuation?.resume(throwing: OperationError.provisioningError(result: "The server didn't give us a cpim", message: nil))
            return
        }
        let body = [
            "Header": [String: Any](),
            "Request": [
                "cpim": cpim,
            ],
        ]
        var request = parentOperation.buildAppleRequest(url: self.endProvisioningURL)
        request.httpMethod = "POST"
        request.httpBody = try! PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
                   let ptm = plist["Response"]?["ptm"] as? String,
                   let tk = plist["Response"]?["tk"] as? String {
                    parentOperation.verboseLog("[FetchAnisetteDataOperation] Giving end provisioning data")
                    client.json(["ptm": ptm, "tk": tk])
                } else {
                    parentOperation.debugLog("[FetchAnisetteDataOperation] Apple didn't give valid end provisioning data! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
                    client.disconnect(closeCode: 0)
                    self.continuation?.resume(throwing: OperationError.provisioningError(result: "Apple didn't give valid end provisioning data. Please try again later", message: nil))
                }
            } catch {
                client.disconnect(closeCode: 0)
                self.continuation?.resume(throwing: error)
            }
        }
    }
    
    private func handleProvisioningSuccess(json: [String: Any], client: WebSocketClient) {
        parentOperation.debugLog("[FetchAnisetteDataOperation] Provisioning succeeded!")
        guard let adiPb = json["adi_pb"] as? String else {
            parentOperation.debugLog("[FetchAnisetteDataOperation] The server didn't give us an adi.pb file")
            client.disconnect(closeCode: 0)
            self.continuation?.resume(throwing: OperationError.provisioningError(result: "The server didn't give us an adi.pb file", message: nil))
            return
        }
        AnisetteDataManager.shared.anisetteAdiBlob = adiPb
        Task {
            do {
                let anisette = try await parentOperation.fetchAnisetteV3(AnisetteDataManager.shared.anisetteIdentifier!, AnisetteDataManager.shared.anisetteAdiBlob!)
                client.disconnect(closeCode: 0)
                self.continuation?.resume(returning: anisette)
            } catch {
                client.disconnect(closeCode: 0)
                self.continuation?.resume(throwing: error)
            }
        }
    }
}

extension WebSocketClient {
    func json(_ dictionary: [String: String]) {
        let data = try! JSONSerialization.data(withJSONObject: dictionary, options: [])
        self.write(string: String(data: data, encoding: .utf8)!)
    }
}

extension Data {
    // https://stackoverflow.com/a/25391020
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0,  count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }
    
    // https://stackoverflow.com/a/40089462
    func hexEncodedString() -> String {
        return self.map { String(format: "%02hhX", $0) }.joined()
    }
    
    // https://stackoverflow.com/a/59127761
    func object<T>() -> T { self.withUnsafeBytes { $0.load(as: T.self) } }
}

final class SafeContinuation<T, E: Error>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, E>?
    private let lock = NSLock()
    
    init(_ continuation: CheckedContinuation<T, E>) {
        self.continuation = continuation
    }
    
    func resume(returning value: T) {
        let continuation = lock.withLock {
            let cont = self.continuation
            self.continuation = nil
            return cont
        }
        continuation?.resume(returning: value)
    }
    
    func resume(throwing error: E) {
        let continuation = lock.withLock {
            let cont = self.continuation
            self.continuation = nil
            return cont
        }
        continuation?.resume(throwing: error)
    }
}

extension HTTPUpgradeError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAnUpgrade(let statusCode, _):
            return "HTTP Upgrade failed (Status \(statusCode))."
        case .invalidData:
            return "Received invalid WebSocket handshake data."
        }
    }
}

extension WSError: @retroactive LocalizedError {
    public var errorDescription: String? {
        return "\(self.message) (code: \(self.code))"
    }
}
