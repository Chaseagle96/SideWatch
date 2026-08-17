//
//  RSTCellContentUpdateableView.swift
//  AltStore
//
//  Created by Magesh K on 6/17/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit

public protocol RSTCellContentUpdateableView: AnyObject {
    func addChange(_ change: RSTCellContentChange)
}

public protocol RSTCellContentTransactionUpdateable: AnyObject {
    func beginUpdates()
    func endUpdates()
}
