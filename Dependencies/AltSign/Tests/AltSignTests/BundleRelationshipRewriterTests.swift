import XCTest
@testable import AltSign

final class BundleRelationshipRewriterTests: XCTestCase {
    func testRewritesNestedWatchRelationships() throws {
        let info: [String: Any] = [
            "WKCompanionAppBundleIdentifier": "com.vendor.app",
            "NSExtension": [
                "NSExtensionAttributes": [
                    "WKAppBundleIdentifier": "com.vendor.app.watchkitapp"
                ]
            ]
        ]
        let rewritten = try ALTBundleRelationshipRewriter.rewrite(
            info,
            identifiers: [
                "com.vendor.app": "TEAM.com.vendor.app",
                "com.vendor.app.watchkitapp": "TEAM.com.vendor.app.watchkitapp"
            ]
        )

        XCTAssertEqual(
            rewritten["WKCompanionAppBundleIdentifier"] as? String,
            "TEAM.com.vendor.app"
        )
        let extensionInfo = try XCTUnwrap(rewritten["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        XCTAssertEqual(
            attributes["WKAppBundleIdentifier"] as? String,
            "TEAM.com.vendor.app.watchkitapp"
        )
    }

    func testRejectsUnmappedRelationship() {
        XCTAssertThrowsError(
            try ALTBundleRelationshipRewriter.rewrite(
                ["WKCompanionAppBundleIdentifier": "com.vendor.missing"],
                identifiers: ["com.vendor.app": "TEAM.com.vendor.app"]
            )
        )
    }
}
