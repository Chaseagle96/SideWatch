//
//  ALTApplication.swift
//  AltSign
//

import Foundation
import SwiftBridge

#if canImport(UIKit)
import UIKit
#endif


public final class ALTApplication: NSObject {

    // MARK: Public Properties

    public let name: String
    public let bundleIdentifier: String
    public let version: String
    public let buildVersion: String

    #if canImport(UIKit)
    public var icon: UIImage? {
        guard let iconName else { return nil }
        return UIImage(
            named: iconName,
            in: bundle,
            compatibleWith: nil
        )
    }
    #endif

    private var _provisioningProfile: ALTProvisioningProfile?
    @objc public var provisioningProfile: ALTProvisioningProfile? {
        if let profile = _provisioningProfile {
            return profile
        }
        let url = fileURL.appendingPathComponent("embedded.mobileprovision")
        _provisioningProfile = ALTProvisioningProfile(url: url)
        return _provisioningProfile
    }
    public var appExtensions: Set<ALTApplication> {
        loadExtensions()
    }

    /// Embedded WatchKit applications are stored in `Watch/*.app`, rather
    /// than in the iOS application's `PlugIns` directory. They must be
    /// treated as independent signing/provisioning units while remaining
    /// part of the parent IPA.
    public var watchApplications: Set<ALTApplication> {
        loadWatchApplications()
    }

    /// Every nested code bundle that requires its own App ID/profile. The
    /// top-level iOS app itself is intentionally excluded.
    public var allEmbeddedApplications: Set<ALTApplication> {
        var result = appExtensions

        for watchApplication in watchApplications {
            result.insert(watchApplication)
            result.formUnion(watchApplication.appExtensions)
        }

        return result
    }

    /// Whether this bundle is a watchOS app or WatchKit extension. Prefer
    /// platform metadata over path matching so the property also works for
    /// bundles opened from a cache or an exported app.
    public var isWatchOSBundle: Bool {
        let info = bundle.infoDictionary ?? [:]
        if let platforms = info["CFBundleSupportedPlatforms"] as? [String],
           platforms.contains(where: { $0.caseInsensitiveCompare("WatchOS") == .orderedSame }) {
            return true
        }

        if let platform = info["DTPlatformName"] as? String,
           platform.caseInsensitiveCompare("watchos") == .orderedSame {
            return true
        }

        if let deviceFamilies = info["UIDeviceFamily"] as? [NSNumber],
           deviceFamilies.contains(where: { $0.intValue == 4 }) {
            return true
        }

        return false
    }

    /// Number of App IDs consumed by this app when extensions are counted.
    public var appIDCount: Int {
        1 + allEmbeddedApplications.count
    }

    public let minimumiOSVersion: OperatingSystemVersion
    public let supportedDeviceTypes: ALTDeviceType

    public var entitlements: [ALTEntitlement: any Sendable] {
        loadEntitlements()
    }

    public var entitlementsString: String {
        loadEntitlementsString()
    }

    public let fileURL: URL
    public let bundle: Bundle

    public var hasPrivateEntitlements: Bool = false

    // MARK: Private

    private let iconName: String?
    private var cachedEntitlements: [ALTEntitlement: any Sendable]?
    private var cachedEntitlementsString: String?

    // MARK: Init

    @objc
    public init?(fileURL: URL) {

        guard let bundle = Bundle(url: fileURL) else {
            return nil
        }

        let infoURL = bundle.bundleURL.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            return nil
        }

        guard
            let bundleIdentifier = info[kCFBundleIdentifierKey as String] as? String
        else { return nil }

        let name =
            (info["CFBundleDisplayName"] as? String)
            ?? (info[kCFBundleNameKey as String] as? String)

        guard let resolvedName = name else { return nil }

        let version =
            (info["CFBundleShortVersionString"] as? String) ?? "1.0"

        let buildVersion =
            (info[kCFBundleVersionKey as String] as? String) ?? "1"

        // MARK: Minimum OS

        let minimumVersionString =
            (info["MinimumOSVersion"] as? String) ?? "1.0"

        let components = minimumVersionString.split(separator: ".")
        let minimumVersion = OperatingSystemVersion(
            majorVersion: Int(components[safe: 0] ?? "1") ?? 1,
            minorVersion: Int(components[safe: 1] ?? "0") ?? 0,
            patchVersion: Int(components[safe: 2] ?? "0") ?? 0
        )

        // MARK: Device Types

        func deviceType(from value: Int) -> ALTDeviceType {
            switch value {
            case 1: return .iPhone
            case 2: return .iPad
            case 3: return .appleTV
            case 4: return .watch
            default: return .none
            }
        }

        var supportedTypes: ALTDeviceType = .none

        if let number = info["UIDeviceFamily"] as? NSNumber {
            supportedTypes = deviceType(from: number.intValue)
        } else if let array = info["UIDeviceFamily"] as? [NSNumber] {
            for value in array {
                supportedTypes.insert(deviceType(from: value.intValue))
            }
        } else {
            supportedTypes = .iPhone
        }

        // MARK: Icon

        var resolvedIcon: String?

        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] {

            if let name = primary as? String {
                resolvedIcon = name
            } else if let dict = primary as? [String: Any] {

                let files =
                    dict["CFBundleIconFiles"]
                    ?? info["CFBundleIconFiles"]

                if let files = files as? [String] {
                    resolvedIcon = files.last
                }
            }
        }

        if resolvedIcon == nil {
            resolvedIcon = info["CFBundleIconFile"] as? String
        }

        self.bundle = bundle
        self.fileURL = fileURL
        self.name = resolvedName
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.buildVersion = buildVersion
        self.minimumiOSVersion = minimumVersion
        self.supportedDeviceTypes = supportedTypes
        self.iconName = resolvedIcon

        super.init()
    }
}

// MARK: - Entitlements

private extension ALTApplication {

    func loadEntitlements() -> [ALTEntitlement: any Sendable] {

        if let cachedEntitlements {
            return cachedEntitlements
        }

        var result: [ALTEntitlement: any Sendable] = [:]

        if !entitlementsString.isEmpty,
           let data = entitlementsString.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
           ) as? [String: Any] {

            result = plist.reduce(into: [ALTEntitlement: any Sendable]()) { dict, pair in
                dict[ALTEntitlement(rawValue: pair.key)] = pair.value
            }
        }

        cachedEntitlements = result
        return result
    }

    func loadEntitlementsString() -> String {

        if let cachedEntitlementsString {
            return cachedEntitlementsString
        }

        let string = (try? LdidBridge.entitlements(at: fileURL)) ?? ""

        cachedEntitlementsString = string
        return string
    }

    @objc
    public func dumpMachOInfo() -> String {
        let executableURL = bundle.executableURL ?? fileURL.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent)
        guard let parser = try? MachOParser(url: executableURL) else {
            return "[AltSign] MachOParser failed to load \(executableURL.lastPathComponent)"
        }
        
        var info = "--- Mach-O Binary Info: \(executableURL.lastPathComponent) ---\n"
        info += "Path: \(fileURL.path)\n"
        info += "Architectures: \(parser.architectures().joined(separator: ", "))\n"
        if let platform = parser.platformType() {
            info += "Platform: \(platform)\n"
        }
        if let minOS = parser.minimumOSVersion() {
            info += "Min OS Version: \(minOS)\n"
        }
        info += "Encrypted (DRM): \(parser.isEncrypted() ? "Yes" : "No")\n"
        if let teamID = parser.teamID() {
            info += "Team ID: \(teamID)\n"
        }
        
        let certs = parser.certificates()
        if !certs.isEmpty {
            info += "Certificates (\(certs.count)):\n"
            for (index, cert) in certs.enumerated() {
                let subject = SecCertificateCopySubjectSummary(cert) as String? ?? "Unknown Subject"
                info += "  [\(index)] \(subject)\n"
            }
        }
        
        let libs = parser.linkedLibraries()
        if !libs.isEmpty {
            info += "Linked Libraries (\(libs.count)):\n"
            for lib in libs {
                info += "  - \(lib)\n"
            }
        }
        
        let segs = parser.segments()
        if !segs.isEmpty {
            info += "Segments (\(segs.count)):\n"
            for seg in segs {
                info += "  - \(seg.name) (offset: \(seg.offset), size: \(seg.size))\n"
            }
        }
        
        info += "----------------------------------------"
        return info
    }
}



// MARK: - Extensions

private extension ALTApplication {

    func loadExtensions() -> Set<ALTApplication> {

        guard let pluginsURL = bundle.builtInPlugInsURL else {
            return []
        }

        var result = Set<ALTApplication>()

        let enumerator = FileManager.default.enumerator(
            at: pluginsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "appex" else {
                continue
            }

            if let ext = ALTApplication(fileURL: url) {
                result.insert(ext)
            }
        }

        return result
    }

    func loadWatchApplications() -> Set<ALTApplication> {
        let fileManager = FileManager.default
        let watchDirectories = [
            bundle.bundleURL.appendingPathComponent("Watch", isDirectory: true),
            bundle.bundleURL.appendingPathComponent("WatchKit", isDirectory: true)
        ]

        var result = Set<ALTApplication>()

        for directory in watchDirectories {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in urls where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true,
                      let application = ALTApplication(fileURL: url),
                      application.isWatchOSBundle else {
                    continue
                }
                result.insert(application)
            }
        }

        return result
    }
}

// MARK: Safe Index

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
