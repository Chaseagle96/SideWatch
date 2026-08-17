//
//  UIApplication+AppExtension.swift
//  DeltaCore
//
//  Created by Riley Testut on 6/14/18.
//  Copyright © 2018 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

public extension UIApplication
{
    // Cannot normally use UIApplication.shared from extensions, so we get around this by calling value(forKey:).
    class var alt_shared: UIApplication? {
        return UIApplication.value(forKey: "sharedApplication") as? UIApplication
    }
    
    var alt_keyWindow: UIWindow? {
        return connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first
    }
}
