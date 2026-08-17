import XCTest
@testable import AltSign

final class BundleIdentifierMappingTests: XCTestCase {
    func testPreservesRootHierarchy() {
        let mapping = ALTBundleIdentifierMapping(
            originalRootIdentifier: "com.vendor.application",
            mappedRootIdentifier: "TEAM.com.vendor.application"
        )

        XCTAssertEqual(
            mapping.mappedIdentifier(for: "com.vendor.application.watchkitapp"),
            "TEAM.com.vendor.application.watchkitapp"
        )
        XCTAssertEqual(
            mapping.mappedIdentifier(for: "com.vendor.application.watchkitapp.watchkitextension"),
            "TEAM.com.vendor.application.watchkitapp.watchkitextension"
        )
    }

    func testUnrelatedIdentifiersAreStableAndUnique() {
        let mapping = ALTBundleIdentifierMapping(
            originalRootIdentifier: "com.vendor.application",
            mappedRootIdentifier: "TEAM.com.vendor.application"
        )
        let first = mapping.mappedIdentifier(for: "org.unrelated.widget")
        let second = mapping.mappedIdentifier(for: "net.unrelated.widget")

        XCTAssertEqual(first, mapping.mappedIdentifier(for: "org.unrelated.widget"))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("TEAM.com.vendor.application.sidewatch.widget."))
    }
}
