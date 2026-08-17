//
//  ALTSignedBundle.swift
//  AltSign
//

import Foundation

/// The install-relevant kind of a signed object embedded in an application.
/// Applications and extensions require provisioning profiles. Frameworks and
/// dynamic libraries are signed code, but do not carry their own profiles.
public enum ALTSignedBundleKind: String, Sendable {
    case iOSApplication
    case iOSExtension
    case watchApplication
    case watchExtension
    case embeddedApplication
    case framework
    case dynamicLibrary

    public var requiresProvisioningProfile: Bool {
        switch self {
        case .iOSApplication, .iOSExtension, .watchApplication, .watchExtension, .embeddedApplication:
            return true
        case .framework, .dynamicLibrary:
            return false
        }
    }
}
public enum ALTBundlePlatform: String, Sendable {
    case iOS
    case watchOS
    case unknown
}

/// A node in the complete nested-code graph for an application bundle.
/// `signingOrder` is post-order, so children are always sealed before their
/// enclosing bundle.
public struct ALTSignedBundleNode {
    public let fileURL: URL
    public let relativePath: String
    public let kind: ALTSignedBundleKind
    public let platform: ALTBundlePlatform
    public let bundleIdentifier: String?
    public let application: ALTApplication?
    public let children: [ALTSignedBundleNode]

    public var requiresProvisioningProfile: Bool {
        kind.requiresProvisioningProfile
    }

    public var signingOrder: [ALTSignedBundleNode] {
        children.flatMap(\.signingOrder) + [self]
    }

    public var provisioningApplications: [ALTApplication] {
        signingOrder.compactMap { node in
            node.requiresProvisioningProfile ? node.application : nil
        }
    }

    init(
        fileURL: URL,
        relativePath: String,
        kind: ALTSignedBundleKind,
        platform: ALTBundlePlatform,
        bundleIdentifier: String?,
        application: ALTApplication?,
        children: [ALTSignedBundleNode]
    ) {
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.kind = kind
        self.platform = platform
        self.bundleIdentifier = bundleIdentifier
        self.application = application
        self.children = children
    }
}
