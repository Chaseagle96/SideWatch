import Foundation
import XCTest
@testable import AltSign

final class EntitlementReconcilerTests: XCTestCase {
    func testRewritesKeychainAndUsesProvisionedGroups() throws {
        let profile = try XCTUnwrap(makeProfile())
        let result = try ALTEntitlementReconciler.reconcile(
            applicationEntitlements: [
                .keychainAccessGroups: ["OLDTEAM.com.example.fixture"],
                .appGroups: ["group.com.example.fixture"],
                "com.apple.developer.associated-domains": ["applinks:example.com"]
            ],
            profile: profile,
            bundleIdentifier: "com.example.fixture"
        )

        XCTAssertEqual(
            result.entitlements[.keychainAccessGroups] as? [String],
            ["TEAM123.com.example.fixture"]
        )
        XCTAssertEqual(
            result.entitlements[.appGroups] as? [String],
            ["group.com.example.fixture.TEAM123"]
        )
        XCTAssertEqual(
            result.entitlements["com.apple.developer.associated-domains"] as? [String],
            ["applinks:example.com"]
        )
    }

    private func makeProfile() -> ALTProvisioningProfile? {
        let entitlements: [String: Any] = [
            "application-identifier": "TEAM123.com.example.fixture",
            "com.apple.developer.team-identifier": "TEAM123",
            "get-task-allow": true,
            "keychain-access-groups": ["TEAM123.*"],
            "com.apple.security.application-groups": ["group.com.example.fixture.TEAM123"],
            "com.apple.developer.associated-domains": ["*"]
        ]
        let dictionary: [String: Any] = [
            "Name": "Fixture",
            "UUID": UUID().uuidString,
            "TeamIdentifier": ["TEAM123"],
            "TeamName": "Fixture Team",
            "CreationDate": Date(),
            "ExpirationDate": Date().addingTimeInterval(3600),
            "Entitlements": entitlements,
            "DeveloperCertificates": [],
            "ProvisionedDevices": ["WATCH-UDID"]
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        ) else {
            return nil
        }
        return ALTProvisioningProfile(data: data)
    }
}
