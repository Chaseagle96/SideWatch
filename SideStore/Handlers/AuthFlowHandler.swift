//
//  AuthFlowHandler.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit
import AltSign

class AuthFlowHandler: AnyObject, AuthenticationHandler, AnisetteServerHandler {
    
    private weak var presentingViewController: UIViewController?
    private weak var presentedAuthVC: AuthenticationViewController?
    
    private var credentialsContinuation: CheckedContinuation<(String, String), Error>?
    private var activeAuthCompletionHandler: ((Result<(ALTAccount, ALTAppleAPISession), Error>) -> Void)?
    
    private lazy var navigationController: UINavigationController = {
        let storyboard = UIStoryboard(name: "Authentication", bundle: nil)
        let navigationController = storyboard.instantiateViewController(withIdentifier: "navigationController") as! UINavigationController
        navigationController.isModalInPresentation = true
        return navigationController
    }()
    
    init(presentingViewController: UIViewController?) {
        self.presentingViewController = presentingViewController
    }
    
    @MainActor
    func credentials() async throws -> (String, String) {
        guard let presentingViewController = self.presentingViewController else {
            throw OperationError.cancelled
        }
        
        if let _ = self.presentedAuthVC {
            return try await withCheckedThrowingContinuation { continuation in
                self.credentialsContinuation = continuation
            }
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.credentialsContinuation = continuation
            
            let storyboard = UIStoryboard(name: "Authentication", bundle: nil)
            let authVC = storyboard.instantiateViewController(withIdentifier: "authenticationViewController") as! AuthenticationViewController
            self.presentedAuthVC = authVC
            
            authVC.authenticationHandler = { [weak self] (appleID, password, completionHandler) in
                guard let self = self else { return }
                self.activeAuthCompletionHandler = completionHandler
                if let credsContinuation = self.credentialsContinuation {
                    self.credentialsContinuation = nil
                    credsContinuation.resume(returning: (appleID, password))
                }
            }
            
            authVC.completionHandler = { [weak self] (result) in
                guard let self = self else { return }
                if result == nil {
                    // Cancelled
                    if let credsContinuation = self.credentialsContinuation {
                        self.credentialsContinuation = nil
                        credsContinuation.resume(throwing: OperationError.cancelled)
                    }
                    self.presentedAuthVC = nil
                    
                    if self.navigationController.presentingViewController != nil {
                        self.navigationController.dismiss(animated: true)
                    }
                } else {
                    // Success (dismissed)
                    self.presentedAuthVC = nil
                }
            }
            
            self.navigationController.view.tintColor = .altInvertedPrimary
            self.navigationController.setViewControllers([authVC], animated: false)
            presentingViewController.present(self.navigationController, animated: true)
        }
    }
    
    @MainActor
    func handleSignInResult(_ result: Result<(ALTAccount, ALTAppleAPISession), Error>) async {
        if let completionHandler = self.activeAuthCompletionHandler {
            self.activeAuthCompletionHandler = nil
            switch result {
            case .success((let account, let session)):
                completionHandler(.success((account, session)))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }
    
    @MainActor
    func verificationCode() async throws -> String? {
        return try await withCheckedThrowingContinuation { continuation in
            let alertController = UIAlertController(title: NSLocalizedString("Please enter the 6-digit verification code that was sent to your Apple devices.", comment: ""), message: nil, preferredStyle: .alert)
            var observer: NSObjectProtocol?
            alertController.addTextField { (textField) in
                textField.autocorrectionType = .no
                textField.autocapitalizationType = .none
                textField.keyboardType = .numberPad
                
                observer = NotificationCenter.default.addObserver(forName: UITextField.textDidChangeNotification, object: textField, queue: .main) { (notification) in
                    guard let textField = notification.object as? UITextField else { return }
                    alertController.actions.first?.isEnabled = (textField.text ?? "").count == 6
                }
            }
            
            let submitAction = UIAlertAction(title: NSLocalizedString("Continue", comment: ""), style: .default) { (action) in
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                let textField = alertController.textFields?.first
                let code = textField?.text ?? ""
                continuation.resume(returning: code)
            }
            submitAction.isEnabled = false
            alertController.addAction(submitAction)
            
            alertController.addAction(UIAlertAction(title: RSTSystemLocalizedString("Cancel"), style: .cancel) { (action) in
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                continuation.resume(returning: nil)
            })
            
            self.present(alertController)
        }
    }
    
    @MainActor
    func resolveRevocation(certificates: [ALTX509Certificate], teamType: ALTTeamType) async throws -> RevokeDecision {
        return try await withCheckedThrowingContinuation { continuation in
            let alertController = UIAlertController(
                title: NSLocalizedString("Revoke Certificates", comment: ""),
                message: NSLocalizedString("Select iOS Development certificate(s) to revoke:", comment: ""),
                preferredStyle: .alert
            )
            
            let revokeVC = RevokeCertificatesAlertViewController(certificates: certificates, teamType: teamType)
            alertController.setValue(revokeVC, forKey: "contentViewController")
            
            let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                if teamType == .free {
                    let warningAlert = UIAlertController(
                        title: NSLocalizedString("Warning", comment: ""),
                        message: NSLocalizedString("SideStore cannot manage the existing certificate without owning its private key. The apps signed with the existing certificate will expire soon unless they are resigned and renewed explicitly by SideStore.", comment: ""),
                        preferredStyle: .alert
                    )
                    warningAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
                        warningAlert.dismiss(animated: true) {
                            continuation.resume(returning: .keepExisting)
                        }
                    })
                    self.present(warningAlert)
                } else {
                    continuation.resume(returning: .keepExisting)
                }
            }
            
            let isPaid = (teamType != .free)
            let initialCount = revokeVC.getSelectedCertificates().count
            let initialTitle = isPaid ? "Revoke Selected (\(initialCount))" : NSLocalizedString("Revoke", comment: "")
            let revokeAction = UIAlertAction(title: initialTitle, style: .destructive) { _ in
                alertController.dismiss(animated: true) {
                    let selected = revokeVC.getSelectedCertificates()
                    continuation.resume(returning: .revokeSelected(selected))
                }
            }
            
            if isPaid {
                revokeAction.isEnabled = !revokeVC.getSelectedCertificates().isEmpty
                revokeVC.onSelectionChanged = { selected in
                    revokeAction.isEnabled = !selected.isEmpty
                    let countText = selected.isEmpty ? "" : " (\(selected.count))"
                    revokeAction.setValue("Revoke Selected\(countText)", forKey: "title")
                }
            }
            
            alertController.addAction(cancelAction)
            alertController.addAction(revokeAction)
            
            self.present(alertController)
        }
    }
    
    @MainActor
    func resolveTeam(_ teams: [ALTTeam]) async throws -> ALTTeam {
        return try await withCheckedThrowingContinuation { continuation in
            let storyboard = UIStoryboard(name: "Authentication", bundle: nil)
            let selectTeamViewController = storyboard.instantiateViewController(withIdentifier: "selectTeamViewController") as! SelectTeamViewController
            selectTeamViewController.teams = teams
            selectTeamViewController.completionHandler = { result in
                continuation.resume(with: result)
            }
            self.present(selectTeamViewController)
        }
    }
    
    @MainActor
    func resolvePostAuth() async {
        await withCheckedContinuation { continuation in
            var hasResumed = false
            let storyboard = UIStoryboard(name: "Authentication", bundle: nil)
            let instructionsViewController = storyboard.instantiateViewController(withIdentifier: "instructionsViewController") as! InstructionsViewController
            instructionsViewController.showsBottomButton = true
            instructionsViewController.completionHandler = {
                guard !hasResumed else {
                    debugLog("[AuthFlowHandler] resolvePostAuth completionHandler invoked more than once. Ignoring.")
                    return
                }
                hasResumed = true
                continuation.resume(returning: ())
            }
            self.present(instructionsViewController)
        }
    }
    
    @MainActor
    func resolveProvisioningError(_ error: Error) async -> ProvisioningErrorDecision {
        return await withCheckedContinuation { continuation in
            let alertController = UIAlertController(
                title: NSLocalizedString("Developer Portal Error", comment: ""),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            
            let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                alertController.dismiss(animated: true) {
                    continuation.resume(returning: .cancel)
                }
            }
            
            let retryAction = UIAlertAction(title: NSLocalizedString("Retry", comment: ""), style: .default) { _ in
                alertController.dismiss(animated: true) {
                    continuation.resume(returning: .retry)
                }
            }
            
            alertController.addAction(cancelAction)
            alertController.addAction(retryAction)
            
            self.present(alertController)
        }
    }
    
    @MainActor
    func resolveResign(mismatchReason: CodeSignValidationReason, context: AuthenticatedOperationContext) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let storyboard = UIStoryboard(name: "Authentication", bundle: nil)
            let resignViewController = storyboard.instantiateViewController(withIdentifier: "resignAltStoreViewController") as! ResignAltStoreViewController
            resignViewController.context = context
            resignViewController.mismatchReason = mismatchReason
            resignViewController.completionHandler = { result in
                guard !hasResumed else {
                    debugLog("[AuthFlowHandler] resolveResign completionHandler invoked more than once. Ignoring.")
                    return
                }
                hasResumed = true
                switch result {
                case .success:
                    continuation.resume(returning: true)
                case .failure:
                    continuation.resume(returning: false)
                }
            }
            self.present(resignViewController)
        }
    }
    
    @MainActor
    func complete() async {
        if self.navigationController.presentingViewController != nil {
            self.navigationController.dismiss(animated: true)
        }
    }
    
    @MainActor
    private func present(_ viewController: UIViewController) {
        if viewController is UIAlertController {
            let anchorVC = self.navigationController.presentingViewController != nil ? self.navigationController : (self.presentingViewController?.presentedViewController ?? self.presentingViewController)
            anchorVC?.present(viewController, animated: true)
            return
        }
        
        if self.navigationController.presentingViewController != nil {
            if self.navigationController.viewControllers.contains(viewController) {
                // Already in stack
            } else {
                viewController.navigationItem.leftBarButtonItem = nil
                self.navigationController.pushViewController(viewController, animated: true)
            }
        } else {
            self.navigationController.setViewControllers([viewController], animated: false)
            let anchorVC = self.presentingViewController?.presentedViewController ?? self.presentingViewController
            anchorVC?.present(self.navigationController, animated: true)
        }
    }



    @MainActor
    func warnOutdatedAnisetteServer() async throws -> Bool {
        guard let presenter = self.presentingViewController else {
            return false
        }
        
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: "WARNING: Outdated anisette server", message: "We've detected you are using an older anisette server. Using this server has a higher likelihood of locking your account and causing other issues. Are you sure you want to continue?", preferredStyle: UIAlertController.Style.alert)
            alert.addAction(UIAlertAction(title: "Continue", style: UIAlertAction.Style.destructive, handler: { action in
                continuation.resume(returning: true)
            }))
            alert.addAction(UIAlertAction(title: "Cancel", style: UIAlertAction.Style.cancel, handler: { action in
                continuation.resume(returning: false)
            }))
            
            presenter.present(alert, animated: true)
        }
    }
}
