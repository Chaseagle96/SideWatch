//
//  FileManager+Zip.swift
//  AltSign
//

import Foundation
import SwiftBridge

extension FileManager {

    // MARK: - Zip POSIX Constants
    // POSIX file type flags (external attributes in ZIP catalog are shifted by 16 bits)
    private static let S_IFREG: UInt32 = 0o100000 // Regular file
    private static let S_IFDIR: UInt32 = 0o040000 // Directory
    private static let S_IFLNK: UInt32 = 0o120000 // Symbolic link
    private static let S_IFMT: UInt32 = 0o170000  // File type mask

    // Default permissions when not defined in the source archive
    private static let defaultFilePermissions: UInt32 = 0o644
    private static let defaultDirPermissions: UInt32 = 0o755

    // MARK: unzipArchive

    func unzipArchive(
        at archiveURL: URL,
        to directoryURL: URL,
        progress: Progress? = nil
    ) throws {
        verboseLog("[AltSign] FileManager.unzipArchive started for archive: \(archiveURL.path) to: \(directoryURL.path)")
        let archive = try ZipBridge.Archive.open(at: archiveURL)
        try archive.goToFirstFile()

        repeat {

            let name = try archive.currentFilename()

            if name.hasPrefix("__MACOSX") {
                verboseLog("[AltSign] FileManager.unzipArchive: skipping __MACOSX entry: \(name)")
                continue
            }

            let pathComponents = name.split(separator: "/", omittingEmptySubsequences: true)
            guard !name.hasPrefix("/"),
                  !pathComponents.contains(where: { $0 == ".." }) else {
                throw ZipError.unsafeArchiveEntry(name)
            }

            let outputURL = directoryURL.appendingPathComponent(name).standardizedFileURL
            let extractionRoot = directoryURL.standardizedFileURL.path
            guard outputURL.path == extractionRoot || outputURL.path.hasPrefix(extractionRoot + "/") else {
                throw ZipError.unsafeArchiveEntry(name)
            }

            let externalAttributes = archive.currentFileExternalAttributes()
            let fileType = (externalAttributes >> 16) & Self.S_IFMT
            var permissions = (externalAttributes >> 16) & 0x01FF
            if permissions == 0 {
                permissions = name.hasSuffix("/") ? Self.defaultDirPermissions : Self.defaultFilePermissions
            }

            if name.hasSuffix("/") {
                verboseLog("[AltSign] FileManager.unzipArchive: creating directory: \(outputURL.path)")
                try createDirectory(
                    at: outputURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: permissions)]
                )
                continue
            }

            if fileType == Self.S_IFLNK {
                let targetData = try archive.readCurrentFile()
                guard let target = String(data: targetData, encoding: .utf8),
                      !target.hasPrefix("/") else {
                    throw ZipError.unsafeSymbolicLink(name)
                }

                let resolvedTarget = outputURL.deletingLastPathComponent()
                    .appendingPathComponent(target)
                    .standardizedFileURL
                guard resolvedTarget.path == extractionRoot || resolvedTarget.path.hasPrefix(extractionRoot + "/") else {
                    throw ZipError.unsafeSymbolicLink("\(name) -> \(target)")
                }

                try createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try createSymbolicLink(atPath: outputURL.path, withDestinationPath: target)
                continue
            }

            verboseLog("[AltSign] FileManager.unzipArchive: extracting file: \(outputURL.path)")
            try createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try archive.extractCurrentFile(to: outputURL)

            if permissions != 0 {
                try setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: outputURL.path)
            }

            if let attributes = try? attributesOfItem(atPath: outputURL.path),
               let size = attributes[.size] as? NSNumber {
                progress?.completedUnitCount += size.int64Value
            }

        } while archive.goToNextFile()
        verboseLog("[AltSign] FileManager.unzipArchive completed successfully")
    }

    public func unzipAppBundle(
        at ipaURL: URL,
        to directoryURL: URL
    ) throws -> URL {
        verboseLog("[AltSign] FileManager.unzipAppBundle starting for: \(ipaURL.path) to: \(directoryURL.path)")
        try unzipArchive(at: ipaURL, to: directoryURL)

        let payload = directoryURL.appendingPathComponent("Payload")
        let contents = try contentsOfDirectory(atPath: payload.path)
        verboseLog("[AltSign] FileManager.unzipAppBundle: checking payload folder contents: \(contents)")

        let applications = contents.filter { file in
            guard file.lowercased().hasSuffix(".app") else { return false }
            var isDirectory: ObjCBool = false
            return fileExists(
                atPath: payload.appendingPathComponent(file).path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
        guard applications.count == 1, let file = applications.first else {
            verboseLog("[AltSign] FileManager.unzipAppBundle error: expected one app, found \(applications.count)")
            throw ZipError.invalidAppBundleCount(ipaURL, applications.count)
        }

        let appURL = payload.appendingPathComponent(file)
        let outputURL = directoryURL.appendingPathComponent(file)

        verboseLog("[AltSign] FileManager.unzipAppBundle: moving app bundle from \(appURL.path) to \(outputURL.path)")
        try moveItem(at: appURL, to: outputURL)
        try removeItem(at: payload)

        verboseLog("[AltSign] FileManager.unzipAppBundle completed. Return app path: \(outputURL.path)")
        return outputURL
    }

    public func unzipAppBundle(at ipaURL: URL, toDirectory directoryURL: URL) throws -> URL {
        return try self.unzipAppBundle(at: ipaURL, to: directoryURL)
    }

    // MARK: zipAppBundle

    public func zipAppBundle(at appBundleURL: URL) throws -> URL {
        verboseLog("[AltSign] FileManager.zipAppBundle starting for: \(appBundleURL.path)")
        let name = appBundleURL.deletingPathExtension().lastPathComponent

        let ipaURL = appBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(name).ipa")

        if fileExists(atPath: ipaURL.path) {
            verboseLog("[AltSign] FileManager.zipAppBundle: removing existing ipa at \(ipaURL.path)")
            try removeItem(at: ipaURL)
        }

        let writer = try ZipBridge.Writer.create(at: ipaURL)
        writer.setCompressLevel(1) // Fast compression level for re-signing

        let payloadRoot = "Payload"
        let bundleRoot = "\(payloadRoot)/\(appBundleURL.lastPathComponent)"

        try writer.writeFile(
            path: payloadRoot + "/",
            data: nil,
            permissions: Self.S_IFDIR | Self.defaultDirPermissions
        )
        let appAttributes = try attributesOfItem(atPath: appBundleURL.path)
        let appPermissions = (appAttributes[.posixPermissions] as? NSNumber)?.uint32Value
            ?? Self.defaultDirPermissions
        try writer.writeFile(
            path: bundleRoot + "/",
            data: nil,
            permissions: Self.S_IFDIR | appPermissions
        )

        let enumerator = self.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )!

        verboseLog("[AltSign] FileManager.zipAppBundle: enumerating contents of app bundle...")
        for case let fileURL as URL in enumerator {

            let resourceValues = try fileURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            let isSymbolicLink = resourceValues.isSymbolicLink == true
            let isDirectory = resourceValues.isDirectory == true && !isSymbolicLink

            let relative = try archiveRelativePath(
                of: fileURL,
                within: appBundleURL
            )

            let zipPath = bundleRoot + "/" + relative + (isDirectory ? "/" : "")

            let attributes = try self.attributesOfItem(atPath: fileURL.path)
            let posixPermissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? (isDirectory ? Self.defaultDirPermissions : Self.defaultFilePermissions)

            verboseLog("[AltSign] FileManager.zipAppBundle: writing zip entry relative: \(relative), path in zip: \(zipPath), isDir: \(isDirectory), isSymlink: \(isSymbolicLink), permissions: \(String(format: "%0o", posixPermissions))")

            if isSymbolicLink {
                let target = try destinationOfSymbolicLink(atPath: fileURL.path)
                let resolvedTarget = fileURL.deletingLastPathComponent()
                    .appendingPathComponent(target)
                    .standardizedFileURL
                let bundlePath = appBundleURL.standardizedFileURL.path
                guard !target.hasPrefix("/"),
                      resolvedTarget.path.hasPrefix(bundlePath + "/"),
                      let data = target.data(using: .utf8) else {
                    throw ZipError.unsafeSymbolicLink("\(relative) -> \(target)")
                }
                let permissions = Self.S_IFLNK + posixPermissions
                try writer.writeFile(path: zipPath, data: data, permissions: permissions)
            } else if isDirectory {
                let permissions = Self.S_IFDIR + posixPermissions
                try writer.writeFile(path: zipPath, data: nil, permissions: permissions)
            } else {
                try writer.addFile(at: fileURL, pathInZip: zipPath)
            }
        }

        verboseLog("[AltSign] FileManager.zipAppBundle completed. Packaged ipa path: \(ipaURL.path)")
        return ipaURL
    }

    private func archiveRelativePath(of itemURL: URL, within rootURL: URL) throws -> String {
        // Directory enumeration on macOS may canonicalize /var to
        // /private/var. Compare against both forms, but do not resolve the
        // item itself because it may be a framework symlink whose archive
        // path must be preserved verbatim.
        let itemPath = itemURL.standardizedFileURL.path
        let roots = [
            rootURL.standardizedFileURL.path,
            rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        ]

        for rootPath in roots {
            let prefix = rootPath + "/"
            if itemPath.hasPrefix(prefix) {
                return String(itemPath.dropFirst(prefix.count))
            }
        }

        throw ZipError.unsafeArchiveEntry(itemPath)
    }
}
