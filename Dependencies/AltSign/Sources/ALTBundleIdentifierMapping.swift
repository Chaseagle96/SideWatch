//
//  ALTBundleIdentifierMapping.swift
//  AltSign
//

import Foundation

/// Deterministically maps every bundle identifier in an IPA into the namespace
/// of the re-signed root application. Prefix-related identifiers keep their
/// original hierarchy. Unrelated identifiers receive a stable collision-safe
/// suffix instead of colliding with the root App ID.
public struct ALTBundleIdentifierMapping: Sendable {
    public let originalRootIdentifier: String
    public let mappedRootIdentifier: String

    public init(originalRootIdentifier: String, mappedRootIdentifier: String) {
        self.originalRootIdentifier = originalRootIdentifier
        self.mappedRootIdentifier = mappedRootIdentifier
    }

    public func mappedIdentifier(for originalIdentifier: String) -> String {
        if originalIdentifier == originalRootIdentifier {
            return mappedRootIdentifier
        }

        if originalIdentifier.hasPrefix(originalRootIdentifier + ".") {
            return mappedRootIdentifier + String(originalIdentifier.dropFirst(originalRootIdentifier.count))
        }

        let leaf = originalIdentifier
            .split(separator: ".")
            .last
            .map(String.init)
            .map(Self.sanitizedComponent) ?? "bundle"
        let digest = String(format: "%016llx", Self.fnv1a64(originalIdentifier))
        return "\(mappedRootIdentifier).sidewatch.\(leaf.prefix(24)).\(digest.prefix(12))"
    }

    private static func sanitizedComponent(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.contains(scalar) || scalar.value == 45
            return allowed ? Character(String(scalar)) : "-"
        }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "bundle" : result
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}
