import Foundation
import XCTest
@testable import AltSign

final class ZipRoundTripTests: XCTestCase {
    func testVersionedFrameworkSymlinksSurviveRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let framework = app.appendingPathComponent(
            "Frameworks/Versioned.framework",
            isDirectory: true
        )
        let version = framework.appendingPathComponent("Versions/A", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(
            to: version.appendingPathComponent("Versioned")
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Versions/Current").path,
            withDestinationPath: "A"
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Versioned").path,
            withDestinationPath: "Versions/Current/Versioned"
        )

        let ipa = try FileManager.default.zipAppBundle(at: app)
        let destination = root.appendingPathComponent("Extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let extracted = try FileManager.default.unzipAppBundle(at: ipa, to: destination)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: extracted.appendingPathComponent(
                    "Frameworks/Versioned.framework/Versions/Current"
                ).path
            ),
            "A"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: extracted.appendingPathComponent(
                    "Frameworks/Versioned.framework/Versioned"
                ).path
            ),
            "Versions/Current/Versioned"
        )
    }
}
