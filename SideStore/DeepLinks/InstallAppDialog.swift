//
//  InstallAppDialog.swift
//  SideStore
//
//  Created by Magesh K on 8/2/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit

@MainActor
public enum InstallAppDialog {
    
    public static func present(
        ipaURL: URL,
        from presentingViewController: UIViewController? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let rootVC = presentingViewController ?? topViewController()
        guard let presentingVC = rootVC else {
            onCancel()
            return
        }
        
        let appName = ipaURL.deletingPathExtension().lastPathComponent
        
        let alert = UIAlertController(
            title: NSLocalizedString("Install App", comment: ""),
            message: String(format: NSLocalizedString("Would you like to install \"%@\"?", comment: ""), appName),
            preferredStyle: .alert
        )
        
        let installAction = UIAlertAction(title: NSLocalizedString("Install", comment: ""), style: .default) { _ in
            onConfirm()
        }
        
        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
            onCancel()
        }
        
        alert.addAction(installAction)
        alert.addAction(cancelAction)
        
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
