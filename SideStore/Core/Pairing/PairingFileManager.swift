//
//  PairingFileManager.swift
//  SideStore
//
//  Created by Magesh K on 17/06/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import UniformTypeIdentifiers

final class PairingFileManager: NSObject {
    static let shared = PairingFileManager()
    static let pairingFileName = "ALTPairingFile.mobiledevicepairing"

    private var completion: ((URL?) -> Void)?

    nonisolated var pairingUDID: String? {
        guard let contents = fetchPairingFile() else { return nil }
        guard let data = contents.data(using: .utf8) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return plist["UDID"] as? String ?? plist["identifier"] as? String
    }

    nonisolated func fetchPairingFile() -> String? {
        let fm = FileManager.default
        let documentsPath = fm.documentsDirectory.appendingPathComponent("/\(Self.pairingFileName)")
        if fm.fileExists(atPath: documentsPath.path),
           let contents = try? String(contentsOf: documentsPath), !contents.isEmpty {
            return contents
        }
        if let url = Bundle.main.url(forResource: "ALTPairingFile", withExtension: "mobiledevicepairing"),
           fm.fileExists(atPath: url.path),
           let data = fm.contents(atPath: url.path),
           let contents = String(data: data, encoding: .utf8),
           !contents.isEmpty, !UserDefaults.standard.isPairingReset { return contents }
        if let plistString = Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") as? String,
           !plistString.isEmpty, !plistString.contains("insert pairing file here"), !UserDefaults.standard.isPairingReset { return plistString }
        return nil
    }

    func savePairingFile(contents: String) throws {
        let fm = FileManager.default
        let documentsPath = fm.documentsDirectory.appendingPathComponent(Self.pairingFileName)
        if fm.fileExists(atPath: documentsPath.path) {
            try? fm.removeItem(at: documentsPath)
        }
        try contents.write(to: documentsPath, atomically: true, encoding: .utf8)
        debugLog("[PairingFile] Successfully copied and saved pairing file to: \(documentsPath.path)")
        UserDefaults.standard.isPairingReset = false
    }
}

// MARK: - UI Extension
extension PairingFileManager: UIDocumentPickerDelegate {
    @MainActor
    func presentPairingFileAlert(on vc: UIViewController, isRetry: Bool, completion: ((URL?) -> Void)? = nil) {
        self.completion = { url in
            completion?(url)
            self.completion = nil
        }
        let title = isRetry ? NSLocalizedString("Invalid Pairing File", comment: "") : NSLocalizedString("Pairing File", comment: "")
        let message = isRetry
            ? NSLocalizedString("The selected pairing file is invalid or not usable. Please select a valid pairing file.", comment: "")
            : NSLocalizedString("Select the pairing file or select \"Help\" for help.", comment: "")
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Help", comment: ""), style: .default) { _ in
            if let url = URL(string: "https://docs.sidestore.io/docs/advanced/pairing-file") { UIApplication.shared.open(url) }
            if completion == nil {
                sleep(2); exit(0)
            } else {
                completion?(nil)
            }
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Select File", comment: ""), style: .default) { _ in
            var types = UTType.types(tag: "plist", tagClass: .filenameExtension, conformingTo: nil)
            types.append(contentsOf: UTType.types(tag: "mobiledevicepairing", tagClass: .filenameExtension, conformingTo: .data))
            types.append(.xml)
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
            picker.delegate = self
            picker.shouldShowFileExtensions = true
            vc.present(picker, animated: true)
            UserDefaults.standard.isPairingReset = false
        })
        
        let cancelTitle = isRetry ? NSLocalizedString("Skip", comment: "") : NSLocalizedString("Cancel", comment: "")
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in
            if completion == nil {
                self.showPairingWarningAndProceed(on: vc)
            } else {
                completion?(nil)
            }
        })
        vc.present(alert, animated: true)
    }
    
    func showPairingWarningAndProceed(on vc: UIViewController) {
        let warningAlert = UIAlertController(
            title: "⚠️ " + NSLocalizedString("Pairing Required", comment: ""),
            message: NSLocalizedString("Without a valid pairing file, operations that require a pairing file (such as installing, refreshing, or resigning apps) will not function.", comment: ""),
            preferredStyle: .alert
        )
        warningAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        vc.present(warningAlert, animated: true)
    }

    func importPairingFile(presentingVC: UIViewController, title: String, message: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.presentPairingFileAlert(on: presentingVC, isRetry: false) { url in
                    if let url = url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: MinimuxerWrapperError.pairingFile)
                    }
                }
            }
        }
    }

    @MainActor
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let url = urls[0]
        let isSecuredURL = url.startAccessingSecurityScopedResource() == true
        defer {
            if (isSecuredURL) {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            debugLog("[PairingFile] User picked pairing file from: \(url.path)")
            let data = try Data(contentsOf: url)
            guard let pairingString = String(data: data, encoding: .utf8) else {
                debugLog("[PairingFile] Unable to read pairing file")
                if let completion = self.completion {
                    completion(nil)
                } else {
                    if let rootVC = UIApplication.shared.alt_keyWindow?.rootViewController {
                        self.presentPairingFileAlert(on: rootVC, isRetry: true)
                    }
                }
                return
            }
            
            // Delegate file operations to the main class
            try savePairingFile(contents: pairingString)
            
            if let completion = self.completion {
                completion(url)
            } else {
                Task.detached {
                    do {
                        try await AppBootManager.shared.startMinimuxer(pairingFile: pairingString)
                    } catch {
                        debugLog("[PairingFile] startMinimuxer failed: \(error)")
                        await MainActor.run {
                            if let rootVC = UIApplication.shared.alt_keyWindow?.rootViewController {
                                self.presentPairingFileAlert(on: rootVC, isRetry: true)
                            }
                        }
                    }
                }
            }
        } catch {
            debugLog("[PairingFile] Error importing pairing file: \(error)")
            if let completion = self.completion {
                completion(nil)
            } else {
                if let rootVC = UIApplication.shared.alt_keyWindow?.rootViewController {
                    self.presentPairingFileAlert(on: rootVC, isRetry: true)
                }
            }
        }
        
        controller.dismiss(animated: true, completion: nil)
    }

    @MainActor
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let completion = self.completion {
            completion(nil)
        } else {
            if let rootVC = UIApplication.shared.alt_keyWindow?.rootViewController {
                self.presentPairingFileAlert(on: rootVC, isRetry: true)
            }
        }
    }
}
