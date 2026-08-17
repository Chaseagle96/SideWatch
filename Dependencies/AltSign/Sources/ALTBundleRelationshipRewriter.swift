//
//  ALTBundleRelationshipRewriter.swift
//  AltSign
//

import Foundation

public enum ALTBundleRelationshipError: LocalizedError {
    case unresolved(key: String, identifier: String)

    public var errorDescription: String? {
        switch self {
        case .unresolved(let key, let identifier):
            return "Bundle relationship '\(key)' references '\(identifier)', but no signed component maps that identifier."
        }
    }
}

/// Rewrites identifiers stored outside CFBundleIdentifier. These references
/// are install-time relationships and must follow the same complete mapping as
/// their target application or extension.
public enum ALTBundleRelationshipRewriter {
    public static let relationshipKeys: Set<String> = [
        "WKCompanionAppBundleIdentifier",
        "WKAppBundleIdentifier",
        "NSExtensionContainingAppBundleIdentifier"
    ]

    public static func rewrite(
        _ dictionary: [String: Any],
        identifiers: [String: String]
    ) throws -> [String: Any] {
        var result = dictionary
        let finalIdentifiers = Set(identifiers.values)

        for (key, value) in dictionary {
            if relationshipKeys.contains(key), let identifier = value as? String {
                if let mapped = identifiers[identifier] {
                    result[key] = mapped
                } else if finalIdentifiers.contains(identifier) {
                    result[key] = identifier
                } else {
                    throw ALTBundleRelationshipError.unresolved(
                        key: key,
                        identifier: identifier
                    )
                }
            } else if let nested = value as? [String: Any] {
                result[key] = try rewrite(nested, identifiers: identifiers)
            } else if let array = value as? [[String: Any]] {
                result[key] = try array.map {
                    try rewrite($0, identifiers: identifiers)
                }
            }
        }
        return result
    }
}
