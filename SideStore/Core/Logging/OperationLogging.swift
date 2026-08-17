//
//  OperationLogging.swift
//  SideStore
//
//  Created by Magesh K on 8/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

internal protocol OperationLogging {
    func debugLog(_ text: @autoclosure () -> String)
    func verboseLog(_ text: @autoclosure () -> String)
}

internal extension OperationLogging {

    func debugLog(_ text: @autoclosure () -> String) {
        let message = text()
        if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
            print(message, terminator: "")
        } else {
            print("\(getOperationsLogTag(level: "[D]"))\(message)")
        }
    }

    func verboseLog(_ text: @autoclosure () -> String) {
        guard OperationsLoggingControl.isLoggingEnabled(for: type(of: self)) else { return }
        let message = text()
        if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
            print(message, terminator: "")
        } else {
            print("\(getOperationsLogTag(level: "[V]"))\(message)")
        }
    }
}
