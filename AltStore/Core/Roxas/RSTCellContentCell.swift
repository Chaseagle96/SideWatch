//
//  RSTCellContentCell.swift
//  AltStore
//
//  Created by Magesh K on 6/17/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit

public protocol RSTCellContentCell: AnyObject {
    static var nib: UINib { get }
    static func instantiate(with nib: UINib) -> Self
}
