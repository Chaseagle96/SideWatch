//
//  ExportCertificateDialog.swift
//  SideStore
//
//  Created by Magesh K on 8/2/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit

@MainActor
public enum ExportCertificateDialog {
    
    public static func present(callbackTemplate: String, presentingViewController: UIViewController? = nil) {
        let rootVC = presentingViewController ?? topViewController()
        guard let presentingVC = rootVC else { return }
        
        let alert = UIAlertController(
            title: NSLocalizedString("Export Certificate", comment: ""),
            message: NSLocalizedString("Do you want to export your certificate to an external app? That app will be able to sign apps using your certificate.", comment: ""),
            preferredStyle: .alert
        )
        
        let exportAction = UIAlertAction(title: NSLocalizedString("Export", comment: ""), style: .default) { _ in
            guard callbackTemplate.contains("$(BASE64_CERT)") else {
                let toast = ToastView(text: NSLocalizedString("No $(BASE64_CERT) placeholder found", comment: ""), detailText: nil)
                toast.show(in: presentingVC)
                return
            }
            
            guard let encodedCert = CertificateManager.shared.activeSigningCertificateBase64Encoded,
                  let password = CertificateManager.shared.activeCertificate?.password else {
                let toast = ToastView(text: NSLocalizedString("Failed to find certificate or password", comment: ""), detailText: nil)
                toast.show(in: presentingVC)
                return
            }
            
            var urlStr = callbackTemplate.replacingOccurrences(of: "$(BASE64_CERT)", with: encodedCert, options: .literal, range: nil)
            urlStr = urlStr.replacingOccurrences(of: "$(PASSWORD)", with: password, options: .literal, range: nil)
            
            guard let callbackURL = URL(string: urlStr) else {
                let toast = ToastView(text: NSLocalizedString("Failed to initialize callback URL!", comment: ""), detailText: nil)
                toast.show(in: presentingVC)
                return
            }
            
            debugLog("[ExportCertificateDialog] Opening certificate callback URL: \(callbackURL.absoluteString)")
            UIApplication.shared.open(callbackURL)
        }
        
        alert.addAction(exportAction)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))
        
        presentingVC.present(alert, animated: true)
    }
    
    @MainActor
    private static func topViewController(base: UIViewController? = nil) -> UIViewController?
    {
        let baseVC = base ?? UIApplication.shared.alt_keyWindow?.rootViewController
            
        if let nav = baseVC as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = baseVC as? UITabBarController {
            if let selected = tab.selectedViewController {
                return topViewController(base: selected)
            }
        }
        if let presented = baseVC?.presentedViewController {
            return topViewController(base: presented)
        }
        return baseVC
    }
}
