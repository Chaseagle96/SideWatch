//
//  SideJITManager.swift
//  SideStore
//
//  Created by Magesh K on 14/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit

public final class SideJITManager {
    public static let shared = SideJITManager()
    
    private init() {}
    
    public func askForNetwork() async {
        let address = UserDefaults.standard.textInputSideJITServerurl ?? ""
        let SJSURL = address.isEmpty ? "http://sidejitserver._http._tcp.local:8080" : address
        guard let url = URL(string: "\(SJSURL)/re/") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2.0
            
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    debugLog("data: \(data), response: \(response)")
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2.0 seconds
                    throw URLError(.timedOut)
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            debugLog("error: \(error)")
        }
    }

    public func isSideJITServerDetected() async throws {
        let address = UserDefaults.standard.textInputSideJITServerurl ?? ""
        let SJSURL = address.isEmpty ? "http://sidejitserver._http._tcp.local:8080" : address
        guard let url = URL(string: SJSURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await URLSession.shared.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2.0 seconds
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

// MARK: - UI Extension
extension SideJITManager {
    @MainActor
    public func presentJITPrompt(presentingVC: UIViewController) {
        let alert = UIAlertController(
            title: "SideJITServer Detected",
            message: "Would you like to enable SideJITServer",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in UserDefaults.standard.sidejitenable = true })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentingVC.present(alert, animated: true)
    }
}
