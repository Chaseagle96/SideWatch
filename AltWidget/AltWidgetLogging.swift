//
//  AltWidgetLogging.swift
//  AltWidget
//
//  Created by Magesh K on 8/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//
import Foundation

internal enum AltWidgetLogging {
    private static let lock = NSLock()
    internal private(set) static var isLoggingEnabled = true
    private static var hasWrittenBootHeader = false

    internal static var isVerboseLoggingEnabled: Bool {
        WidgetDataManager.shared.isVerboseLoggingEnabled
    }

    internal static func setLogging(_ enabled: Bool) {
        lock.withLock {
            isLoggingEnabled = enabled
        }
    }
    
    fileprivate static func logToFile(_ text: String) {
        guard let url = WidgetLogManager.widgetLogURL ?? FileManager.default.altstoreSharedDirectory?.appendingPathComponent("widget.log") else {
            return
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        if !fileExists {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        
        let fd = handle.fileDescriptor
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        
        handle.seekToEndOfFile()
        
        if !hasWrittenBootHeader {
            hasWrittenBootHeader = true
            let date = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let dateString = formatter.string(from: date)
            
            let totalWidth = 51
            let innerWidth = totalWidth - 2
            let leftPadLength = max(0, (innerWidth - dateString.count) / 2)
            let rightPadLength = max(0, innerWidth - dateString.count - leftPadLength)
            let leftPadding = String(repeating: " ", count: leftPadLength)
            let rightPadding = String(repeating: " ", count: rightPadLength)
            
            let header = """
            
            ===================================================
            |              Widget is Starting up              |
            ===================================================
            | Widget Logger started capturing output streams  |
            ===================================================
            |\(leftPadding)\(dateString)\(rightPadding)|
            ===================================================
            
            """
            if let headerData = header.data(using: .utf8) {
                handle.write(headerData)
            }
        }
        
        if let data = (text + "\n").data(using: .utf8) {
            handle.write(data)
        }
    }
}

private func getTag(level: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let timestamp = formatter.string(from: Date())
    return "\(timestamp) \(level): "
}

@inline(__always)
internal func debugLog(_ text: @autoclosure () -> String) {
    let message = text()
    if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
        print(message, terminator: "")
        AltWidgetLogging.logToFile(message)
    } else {
        let formatted = "\(getTag(level: "[D]"))\(message)"
        print(formatted)
        AltWidgetLogging.logToFile(formatted)
    }
}

@inline(__always)
internal func verboseLog(_ text: @autoclosure () -> String) {
    if AltWidgetLogging.isLoggingEnabled && AltWidgetLogging.isVerboseLoggingEnabled {
        let message = text()
        if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
            print(message, terminator: "")
            AltWidgetLogging.logToFile(message)
        } else {
            let formatted = "\(getTag(level: "[V]"))\(message)"
            print(formatted)
            AltWidgetLogging.logToFile(formatted)
        }
    }
}
