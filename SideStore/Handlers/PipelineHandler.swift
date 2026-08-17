//
//  PipelineHandler.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit
import AltSign

class PipelineHandler: PipelineExecutionHandler, 
                         PreflightChecksHandler, 
                         EntitlementsReviewHandler, 
                         ExtensionRemovalHandler, 
                         UnsupportedVersionHandler, 
                         InstallAppHandler, 
                         UserCustomizationHandler 
{
    
    var preflightChecksHandler: PreflightChecksHandler { self }
    var entitlementsReviewHandler: EntitlementsReviewHandler { self }
    var extensionRemovalHandler: ExtensionRemovalHandler { self }
    var unsupportedVersionHandler: UnsupportedVersionHandler { self }
    var installAppHandler: InstallAppHandler { self }
    var userCustomizationHandler: UserCustomizationHandler { self }
    
    private weak var presentingViewController: UIViewController?
    
    init(presentingViewController: UIViewController?) {
        self.presentingViewController = presentingViewController
    }
    
    var isResignActive: Bool {
        return presentingViewController is ResignAltStoreViewController
    }
    
    @MainActor
    func resolveBundleIDMismatch(targetID: String, activeEffectiveID: String) async -> Bool {
        guard let presenter = self.presentingViewController else {
            return false
        }
        
        let title = NSLocalizedString("Bundle ID Mismatch", comment: "")
        let message = String(format: NSLocalizedString("The app you are installing has a bundle ID (%@) that does not match the active app (%@). Would you like to proceed?", comment: ""), targetID, activeEffectiveID)
        
        return await withCheckedContinuation { continuation in
            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: UIAlertAction.cancel.title, style: UIAlertAction.cancel.style) { _ in
                continuation.resume(returning: false)
            })
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Proceed", comment: ""), style: .default) { _ in
                continuation.resume(returning: true)
            })
            presenter.present(alertController, animated: true)
        }
    }
    
    @MainActor
    func reviewPermissions(_ permissions: [ALTEntitlement], for app: AppProtocol, mode: PermissionReviewMode) async throws {
        guard let presenter = self.presentingViewController else {
            throw OperationError.cancelled
        }
        let reviewPermissionsViewController = ReviewPermissionsViewController(app: app, permissions: permissions, mode: mode)
        let navigationController = UINavigationController(rootViewController: reviewPermissionsViewController)
        
        defer {
            navigationController.dismiss(animated: true)
        }
        
        try await withCheckedThrowingContinuation { continuation in
            reviewPermissionsViewController.completionHandler = { result in
                continuation.resume(with: result)
            }
            
            presenter.present(navigationController, animated: true)
        }
    }
    
    @MainActor
    func selectAppExtensionsToRemove(
        appBundle: ALTApplication,
        localAppExtensions: [ALTApplication],
        excessExtensions: Set<ALTApplication>
    ) async throws -> ExtensionRemovalDecision {
        guard let presenter = self.presentingViewController else {
            return .keepAll(useMainProfile: false)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let firstSentence: String
            if UserDefaults.standard.activeAppLimitIncludesExtensions {
                firstSentence = NSLocalizedString("Non-developer Apple IDs are limited to 3 active apps and app extensions.", comment: "")
            } else {
                firstSentence = NSLocalizedString("Non-developer Apple IDs are limited to creating 10 App IDs per week.", comment: "")
            }
            
            let message = firstSentence + " " + NSLocalizedString("Would you like to remove this app's extensions so they don't count towards your limit? There are \(appBundle.appExtensions.count) Extensions", comment: "")
            
            let alertController = UIAlertController(title: NSLocalizedString("App Contains Extensions", comment: ""), message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: UIAlertAction.cancel.title, style: UIAlertAction.cancel.style, handler: { _ in
                continuation.resume(throwing: OperationError.cancelled)
            }))
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Keep App Extensions (Use Main Profile)", comment: ""), style: .default) { _ in
                continuation.resume(returning: .keepAll(useMainProfile: true))
            })
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Keep App Extensions (Register App ID for Each Extension)", comment: ""), style: .default) { _ in
                continuation.resume(returning: .keepAll(useMainProfile: false))
            })
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Remove App Extensions", comment: ""), style: .destructive) { _ in
                continuation.resume(returning: .removeAll)
            })
            
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Choose App Extensions", comment: ""), style: .default) { _ in
                let popoverContentController = AppExtensionViewHostingController(extensions: appBundle.appExtensions) { selection in
                    continuation.resume(returning: .removeSelected(Set(selection)))
                }
                
                let suiview = popoverContentController.view!
                suiview.translatesAutoresizingMaskIntoConstraints = false
                popoverContentController.modalPresentationStyle = .popover
                
                if let popoverPresentationController = popoverContentController.popoverPresentationController {
                    popoverPresentationController.sourceView = presenter.view
                    popoverPresentationController.sourceRect = CGRect(x: 50, y: 50, width: 4, height: 4)
                    popoverPresentationController.delegate = popoverContentController
                    presenter.present(popoverContentController, animated: true)
                } else {
                    continuation.resume(throwing: OperationError.invalidParameters("RemoveAppExtensionsOperation: popoverContentController.popoverPresentationController is nil"))
                }
            })
            
            presenter.present(alertController, animated: true) {
                if presenter.presentedViewController == nil && !alertController.isViewLoaded {
                    let errMsg = "RemoveAppExtensionsOperation: unable to present dialog, view context not available." +
                                 "\nDid you move to different screen or background after starting the operation?"
                    continuation.resume(throwing: OperationError.invalidOperationContext(errMsg))
                }
            }
        }
    }
    
    @MainActor
    func resolveUnsupportediOSVersion(errorDescription: String, appName: String, compatibleVersion: String) async throws -> Bool {
        guard let presenter = self.presentingViewController else {
            return false
        }
        
        let title = NSLocalizedString("Unsupported iOS Version", comment: "")
        let message = errorDescription + "\n\n" + NSLocalizedString("Would you like to download the last version compatible with this device instead?", comment: "")
        
        return await withCheckedContinuation { continuation in
            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: UIAlertAction.cancel.title, style: UIAlertAction.cancel.style) { _ in
                continuation.resume(returning: false)
            })
            alertController.addAction(UIAlertAction(title: String(format: NSLocalizedString("Download %@ %@", comment: ""), appName, compatibleVersion), style: .default) { _ in
                continuation.resume(returning: true)
            })
            presenter.present(alertController, animated: true)
        }
    }
    
    func requestBackgroundSuspension(completion: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let alert = UIAlertController(
                title: "Finish Refresh",
                message: """
                To finish refreshing, SideStore must be moved to the background. To do this, you can either go to the Home Screen manually or by hitting Continue. Please reopen SideStore after doing this.
                """,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NSLocalizedString("Continue", comment: ""), style: .default, handler: { _ in
                completion()
            }))
            
            let presenter = self.presentingViewController
                            ?? UIApplication.shared.connectedScenes
                                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                                .first?.rootViewController
                                
            if var topVC = presenter {
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }
                topVC.present(alert, animated: true)
            } else {
                completion()
            }
        }
    }
    
    func suspendToHomeScreen(shouldTurnOffData: Bool) {
        DispatchQueue.main.async {
            if shouldTurnOffData {
                let shortcutURLonDelay = URL(string: "shortcuts://run-shortcut?name=TurnOnDataDelay")!
                UIApplication.shared.open(shortcutURLonDelay, options: [:])
            }
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        }
    }
    
    var isAppInForeground: Bool {
        if Thread.isMainThread {
            return UIApplication.shared.applicationState == .active
        } else {
            return DispatchQueue.main.sync {
                UIApplication.shared.applicationState == .active
            }
        }
    }
    
    @MainActor
    func resolveBundleIDOverride(initialBundleID: String) async throws -> String? {
        guard let presenter = self.presentingViewController else {
            return initialBundleID
        }
        
        let titleText = NSLocalizedString("AppID Customization", comment: "")
        let messageText = NSLocalizedString("Customize the AppID if required and press 'Confirm' to proceed.", comment: "")
        
        let alert = UIAlertController(
            title: titleText,
            message: messageText,
            preferredStyle: .alert
        )
        
        alert.addTextField { textField in
            textField.text = initialBundleID
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        
        return await withCheckedContinuation { continuation in
            let okAction = UIAlertAction(title: NSLocalizedString("Confirm", comment: ""), style: .default) { _ in
                continuation.resume(returning: alert.textFields?.first?.text ?? initialBundleID)
            }
            
            let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                continuation.resume(returning: nil)
            }
            alert.addAction(cancelAction)
            alert.addAction(okAction)
            presenter.present(alert, animated: true)
        }
    }

    @MainActor
    func resolveAppGroupMismatch(originalGroup: String, correctedGroup: String) async throws -> AppGroupResolution {
        guard let presenter = self.presentingViewController else {
            return .correctAndProceed(correctedGroup)
        }
        
        let title = NSLocalizedString("App Group Discrepancy", comment: "")
        let message = String(format: NSLocalizedString("The app group '%@' does not match the app's bundle ID casing. Would you like to correct it to '%@'?", comment: ""), originalGroup, correctedGroup)
        
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            
            alert.addAction(UIAlertAction(title: NSLocalizedString("Correct & Proceed", comment: ""), style: .default) { _ in
                continuation.resume(returning: .correctAndProceed(correctedGroup))
            })
            
            alert.addAction(UIAlertAction(title: NSLocalizedString("Keep Original", comment: ""), style: .destructive) { _ in
                continuation.resume(returning: .keepOriginal(originalGroup))
            })
            
            alert.addAction(UIAlertAction(title: UIAlertAction.cancel.title, style: .cancel) { _ in
                continuation.resume(returning: .keepOriginal(originalGroup))
            })
            
            presenter.present(alert, animated: true)
        }
    }
}
