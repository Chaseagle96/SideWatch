import Foundation
import XCTest
@testable import AltSign

final class SignedBundleGraphTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testMixedGraphIsRecursiveAndPostOrder() throws {
        let root = try makeBundle(
            at: temporaryDirectory.appendingPathComponent("Fixture.app"),
            identifier: "com.example.fixture",
            executable: "Fixture",
            watch: false
        )
        _ = try makeBundle(
            at: root.appendingPathComponent("PlugIns/Widget.appex"),
            identifier: "com.example.fixture.widget",
            executable: "Widget",
            watch: false
        )
        let watch = try makeBundle(
            at: root.appendingPathComponent("Watch/FixtureWatch.app"),
            identifier: "com.example.fixture.watchkitapp",
            executable: "FixtureWatch",
            watch: true
        )
        _ = try makeBundle(
            at: watch.appendingPathComponent("PlugIns/WatchExtension.appex"),
            identifier: "com.example.fixture.watchkitapp.watchkitextension",
            executable: "WatchExtension",
            watch: true
        )
        let watchFramework = try makeBundle(
            at: watch.appendingPathComponent("Frameworks/WatchSupport.framework"),
            identifier: "com.example.watchsupport",
            executable: "WatchSupport",
            watch: true
        )
        _ = try makeBundle(
            at: watchFramework.appendingPathComponent("Frameworks/Nested.framework"),
            identifier: "com.example.nested",
            executable: "Nested",
            watch: true
        )

        let application = try XCTUnwrap(ALTApplication(fileURL: root))
        let graph = application.signedBundleGraph
        let order = graph.signingOrder.map(\.relativePath)

        XCTAssertEqual(application.appIDCount, 4)
        XCTAssertEqual(application.watchApplications.count, 1)
        XCTAssertTrue(
            order.contains("Watch/FixtureWatch.app/Frameworks/WatchSupport.framework"),
            "Discovered signing order: \(order)"
        )
        let nestedFrameworkIndex = try XCTUnwrap(
            order.firstIndex(of: "Watch/FixtureWatch.app/Frameworks/WatchSupport.framework/Frameworks/Nested.framework")
        )
        let watchFrameworkIndex = try XCTUnwrap(
            order.firstIndex(of: "Watch/FixtureWatch.app/Frameworks/WatchSupport.framework")
        )
        XCTAssertLessThan(nestedFrameworkIndex, watchFrameworkIndex)
        let extensionIndex = try XCTUnwrap(
            order.firstIndex(of: "Watch/FixtureWatch.app/PlugIns/WatchExtension.appex")
        )
        let watchAppIndex = try XCTUnwrap(order.firstIndex(of: "Watch/FixtureWatch.app"))
        XCTAssertLessThan(extensionIndex, watchAppIndex)
        XCTAssertEqual(order.last, "")
    }

    private func makeBundle(
        at url: URL,
        identifier: String,
        executable: String,
        watch: Bool
    ) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": executable,
            "CFBundleName": executable,
            "CFBundleDisplayName": executable,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleSupportedPlatforms": [watch ? "WatchOS" : "iPhoneOS"],
            "DTPlatformName": watch ? "watchos" : "iphoneos",
            "UIDeviceFamily": watch ? [4] : [1, 2]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: url.appendingPathComponent("Info.plist"))
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: url.appendingPathComponent(executable))
        return url
    }
}
