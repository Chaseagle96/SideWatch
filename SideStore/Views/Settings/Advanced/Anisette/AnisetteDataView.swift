//  AnisetteDataView.swift
//  SideStore
//
//  Created by Magesh K on 31/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
class AnisetteDataViewModel: ObservableObject {
    @Published var clientInfo: String = ""
    @Published var userAgent: String = ""
    @Published var customDeviceID: String = ""
    @Published var customLocalUserID: String = ""
    @Published var customLocale: String = ""
    @Published var customTimeZone: String = ""
    
    @Published var isOfflineMode: Bool = false
    @Published var isLoading: Bool = false
    
    @Published var viewMode: Int = 0 // 0 = Interactive, 1 = Raw JSON
    @Published var rawEditableJSON: String = ""
    @Published var serverReturnedHeadersJSON: String = "{}"
    
    init() {
        Task {
            await loadData()
        }
    }
    
    func loadData() async {
        isOfflineMode = AnisetteConfigManager.shared.isOfflineMode
        let config = await AnisetteConfigManager.shared.loadConfig()
        clientInfo = config.clientInfo
        userAgent = config.userAgent
        customDeviceID = config.customDeviceID ?? ""
        customLocalUserID = config.customLocalUserID ?? ""
        customLocale = config.customLocale ?? ""
        customTimeZone = config.customTimeZone ?? ""
        
        updateRawEditableJSON()
        
        let serverHeaders = await AnisetteConfigManager.shared.loadServerHeaders()
        if let data = try? JSONSerialization.data(withJSONObject: serverHeaders, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            serverReturnedHeadersJSON = str
        }
    }
    
    func updateRawEditableJSON() {
        var dict: [String: String] = [
            "clientInfo": clientInfo,
            "userAgent": userAgent
        ]
        if !customDeviceID.isEmpty { dict["customDeviceID"] = customDeviceID }
        if !customLocalUserID.isEmpty { dict["customLocalUserID"] = customLocalUserID }
        if !customLocale.isEmpty { dict["customLocale"] = customLocale }
        if !customTimeZone.isEmpty { dict["customTimeZone"] = customTimeZone }
        
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            rawEditableJSON = str
        }
    }
    
    func save() async {
        AnisetteConfigManager.shared.isOfflineMode = isOfflineMode
        let config = AnisetteConfig(
            clientInfo: clientInfo,
            userAgent: userAgent,
            customDeviceID: customDeviceID.isEmpty ? nil : customDeviceID,
            customLocalUserID: customLocalUserID.isEmpty ? nil : customLocalUserID,
            customLocale: customLocale.isEmpty ? nil : customLocale,
            customTimeZone: customTimeZone.isEmpty ? nil : customTimeZone
        )
        await AnisetteConfigManager.shared.saveConfig(config)
        updateRawEditableJSON()
        showToast(text: "Saved configuration successfully.")
    }
    
    func saveRawJSON() async {
        guard let data = rawEditableJSON.data(using: .utf8) else {
            showToast(text: "Encoding Failed", detailText: "Unable to encode JSON as UTF-8.")
            return
        }
        
        do {
            let config = try Foundation.JSONDecoder().decode(AnisetteConfig.self, from: data)
            
            clientInfo = config.clientInfo
            userAgent = config.userAgent
            customDeviceID = config.customDeviceID ?? ""
            customLocalUserID = config.customLocalUserID ?? ""
            customLocale = config.customLocale ?? ""
            customTimeZone = config.customTimeZone ?? ""
            
            await AnisetteConfigManager.shared.saveConfig(config)
            showToast(text: "JSON configuration saved successfully!")
        } catch {
            showToast(text: "Invalid JSON Structure", error: error)
        }
    }
    
    func reset() async {
        let config = await AnisetteConfigManager.shared.resetToDefaults()
        clientInfo = config.clientInfo
        userAgent = config.userAgent
        customDeviceID = ""
        customLocalUserID = ""
        customLocale = ""
        customTimeZone = ""
        updateRawEditableJSON()
        await save()
        showToast(text: "Reset to default configuration.")
    }
    
    func importJSON(url: URL) async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gotAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            let config = try await AnisetteConfigManager.shared.importFromFile(url: url)
            clientInfo = config.clientInfo
            userAgent = config.userAgent
            customDeviceID = config.customDeviceID ?? ""
            customLocalUserID = config.customLocalUserID ?? ""
            customLocale = config.customLocale ?? ""
            customTimeZone = config.customTimeZone ?? ""
            updateRawEditableJSON()
            showToast(text: "Imported successfully", detailText: url.lastPathComponent)
        } catch {
            showToast(text: "Import Failed", error: error)
        }
    }
    
    func exportJSON() async -> URL? {
        guard let data = await AnisetteConfigManager.shared.exportConfigData() else { return nil }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("anisette-config.json")
        do {
            try data.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            showToast(text: "Export Failed", error: error)
            return nil
        }
    }
    
    func fetchFreshFromServer() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let activeServer = UserDefaults.standard.menuAnisetteURL
            guard !activeServer.isEmpty, let url = URL(string: activeServer) else {
                throw NSError(domain: "AnisetteDataViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active anisette server URL configured."])
            }
            
            let clientInfoURL = url.appendingPathComponent("v3").appendingPathComponent("client_info")
            var request = URLRequest(url: clientInfoURL)
            request.timeoutInterval = 10
            
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw NSError(domain: "AnisetteDataViewModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "Server response is not a valid JSON."])
            }
            
            // Save the server returned headers
            await AnisetteConfigManager.shared.saveServerHeaders(json)
            
            // Refresh the server headers display
            let serverHeaders = await AnisetteConfigManager.shared.loadServerHeaders()
            if let data = try? JSONSerialization.data(withJSONObject: serverHeaders, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                serverReturnedHeadersJSON = str
            }
            
            showToast(text: "Fetched server config!", detailText: url.host)
        } catch {
            showToast(text: "Fetch Failed", error: error)
        }
    }
    
    func loadServerHeadersIntoOverrides() async {
        let serverHeaders = await AnisetteConfigManager.shared.loadServerHeaders()
        guard !serverHeaders.isEmpty else {
            showToast(text: "No fetched headers found", detailText: "Fetch from server first.")
            return
        }
        
        // Casing helper to lookup keys flexibly in both camelCase and snake_case
        func getValue(forKeys keys: [String]) -> String? {
            for key in keys {
                if let val = serverHeaders[key] {
                    return val
                }
            }
            return nil
        }
        
        if let val = getValue(forKeys: ["client_info", "clientInfo", "X-Mme-Client-Info"]) {
            clientInfo = val
        }
        if let val = getValue(forKeys: ["user_agent", "userAgent", "User-Agent"]) {
            userAgent = val
        }
        if let val = getValue(forKeys: ["custom_device_id", "customDeviceID", "X-Mme-Device-Id", "deviceUniqueIdentifier"]) {
            customDeviceID = val
        }
        if let val = getValue(forKeys: ["custom_local_user_id", "customLocalUserID", "X-Apple-I-MD-LU", "localUserID"]) {
            customLocalUserID = val
        }
        if let val = getValue(forKeys: ["custom_locale", "customLocale", "X-Apple-Locale", "locale"]) {
            customLocale = val
        }
        if let val = getValue(forKeys: ["custom_time_zone", "customTimeZone", "X-Apple-I-TimeZone", "timeZone"]) {
            customTimeZone = val
        }
        
        // Save and update
        await save()
        showToast(text: "Loaded fetched data into overrides!")
    }
    
    func showToast(text: String, detailText: String? = nil, error: Error? = nil) {
        let toast: ToastView
        if let error = error {
            toast = ToastView(error: error, opensLog: true)
        } else {
            toast = ToastView(text: text, detailText: detailText)
        }
        
        let keyWindow = UIApplication.shared.alt_keyWindow
        if let rootVC = keyWindow?.rootViewController {
            let presentingVC = rootVC.presentedViewController ?? rootVC
            toast.show(in: presentingVC)
        }
    }
}

struct AnisetteDataView: View {
    @StateObject private var viewModel = AnisetteDataViewModel()
    @State private var showingResetAlert = false
    @State private var showingFileImporter = false
    @State private var showingShareSheet = false
    @State private var exportFileURL: URL? = nil
    @State private var isCopiedServer = false
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("View Mode", selection: $viewModel.viewMode) {
                Text("Interactive").tag(0)
                Text("Raw JSON").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            .background(Color(.systemGroupedBackground))
            
            List {
                // Section 1: Operational Mode
                Section {
                    Toggle(isOn: $viewModel.isOfflineMode) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use Offline Config File")
                                .font(.body)
                            Text("Bypasses fetching client info from servers")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: viewModel.isOfflineMode) { _ in
                        Task {
                            await viewModel.save()
                        }
                    }
                } header: {
                    Text("Operational Mode")
                } footer: {
                    Text("When enabled, SideStore uses the locally saved JSON configuration parameters for all authentication headers without making client_info requests to servers.")
                }
                
                if viewModel.viewMode == 0 {
                    // SECTION 2: INTERACTIVE CUSTOMIZATION
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Client Info (X-Mme-Client-Info)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            
                            TextEditor(text: $viewModel.clientInfo)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 80)
                                .padding(4)
                                .background(Color(.secondarySystemGroupedBackground))
                                .cornerRadius(6)
                        }
                        .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("User Agent")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            
                            TextEditor(text: $viewModel.userAgent)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 80)
                                .padding(4)
                                .background(Color(.secondarySystemGroupedBackground))
                                .cornerRadius(6)
                        }
                        .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Device ID Override (Optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            
                            TextField("System Generated", text: $viewModel.customDeviceID)
                                .font(.system(.caption, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(8)
                                .background(Color(.secondarySystemGroupedBackground))
                                .cornerRadius(6)
                        }
                        .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Local User ID Override (Optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            
                            TextField("System Generated", text: $viewModel.customLocalUserID)
                                .font(.system(.caption, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(8)
                                .background(Color(.secondarySystemGroupedBackground))
                                .cornerRadius(6)
                        }
                        .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Locale Override (Optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            
                            TextField("e.g. en_US", text: $viewModel.customLocale)
                                .font(.system(.caption, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(8)
                                .background(Color(.secondarySystemGroupedBackground))
                                .cornerRadius(6)
                        }
                        .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Time Zone Override (Optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            
                            TextField("e.g. UTC, GMT", text: $viewModel.customTimeZone)
                                .font(.system(.caption, design: .monospaced))
                                .autocapitalization(.allCharacters)
                                .disableAutocorrection(true)
                                .padding(8)
                                .background(Color(.secondarySystemGroupedBackground))
                                .cornerRadius(6)
                        }
                        .padding(.vertical, 4)
                        
                        SwiftUI.Button {
                            Task {
                                await viewModel.save()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text("Save Overrides")
                                    .font(.headline)
                                Spacer()
                            }
                        }
                        .disabled(viewModel.clientInfo.isEmpty || viewModel.userAgent.isEmpty)
                    } header: {
                        Text("Custom Parameters")
                    }
                } else {
                    // SECTION 3: RAW JSON VIEW
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Configuration JSON (Editable)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            
                            TextEditor(text: $viewModel.rawEditableJSON)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 300)
                                .padding(4)
                                .background(Color(.secondarySystemGroupedBackground))
                                .cornerRadius(6)
                        }
                        .padding(.vertical, 4)
                        
                        SwiftUI.Button {
                            Task {
                                await viewModel.saveRawJSON()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text("Save Raw JSON")
                                    .font(.headline)
                                Spacer()
                            }
                        }
                        .disabled(viewModel.rawEditableJSON.isEmpty)
                    } header: {
                        Text("Raw Configuration JSON")
                    }
                }
                
                // SECTION 4: SERVER RETURNED HEADERS (READ-ONLY)
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Last Server Response JSON")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            SwiftUI.Button {
                                UIPasteboard.general.string = viewModel.serverReturnedHeadersJSON
                                withAnimation {
                                    isCopiedServer = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation {
                                        isCopiedServer = false
                                    }
                                }
                            } label: {
                                Image(systemName: isCopiedServer ? "checkmark" : "doc.on.doc")
                                    .font(.footnote)
                                    .foregroundColor(isCopiedServer ? .green : .accentColor)
                            }
                        }
                        
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(viewModel.serverReturnedHeadersJSON)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(8)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(6)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    SwiftUI.Button {
                        Task {
                            await viewModel.loadServerHeadersIntoOverrides()
                        }
                    } label: {
                        Label("Load Fetched Data into Overrides", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(viewModel.serverReturnedHeadersJSON == "{}" || viewModel.serverReturnedHeadersJSON.isEmpty)
                } header: {
                    Text("Server Returned Headers (Read-Only)")
                } footer: {
                    Text("Displays raw headers cached from successful anisette server handshakes. Use this to copy exact parameters sent by client/server.")
                }
                
                // SECTION 5: ACTIONS
                Section {
                    SwiftUI.Button {
                        Task {
                            await viewModel.fetchFreshFromServer()
                        }
                    } label: {
                        Label("Fetch Fresh from Active Server", systemImage: "arrow.clockwise")
                    }
                    
                    SwiftUI.Button {
                        showingFileImporter = true
                    } label: {
                        Label("Import Config JSON", systemImage: "square.and.arrow.down")
                    }
                    
                    SwiftUI.Button {
                        Task {
                            if let url = await viewModel.exportJSON() {
                                exportFileURL = url
                                showingShareSheet = true
                            }
                        }
                    } label: {
                        Label("Export Config JSON", systemImage: "square.and.arrow.up")
                    }
                    
                    SwiftUI.Button(role: .destructive) {
                        showingResetAlert = true
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.circlepath")
                            .foregroundColor(.red)
                    }
                    .alert("Reset to Defaults?", isPresented: $showingResetAlert) {
                        SwiftUI.Button("Reset", role: .destructive) {
                            Task {
                                await viewModel.reset()
                            }
                        }
                        SwiftUI.Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will restore the client headers to the default recommended macOS values.")
                    }
                } header: {
                    Text("Actions")
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Client Config")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
                        .shadow(radius: 10)
                }
            }
        )
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        await viewModel.importJSON(url: url)
                    }
                }
            case .failure(let error):
                viewModel.showToast(text: "File Selection Failed", error: error)
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let fileURL = exportFileURL {
                ActivityViewController(activityItems: [fileURL])
            }
        }
    }
}
