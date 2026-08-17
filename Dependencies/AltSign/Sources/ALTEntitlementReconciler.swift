//
//  ALTEntitlementReconciler.swift
//  AltSign
//

import Foundation

public struct ALTEntitlementReconciliationResult {
    public let entitlements: [ALTEntitlement: any Sendable]
    public let diagnostics: [String]
}

public enum ALTEntitlementReconciler {
    public static func reconcile(
        applicationEntitlements: [ALTEntitlement: any Sendable],
        profile: ALTProvisioningProfile,
        bundleIdentifier: String
    ) throws -> ALTEntitlementReconciliationResult {
        let permitted = profile.entitlements
        var final: [ALTEntitlement: any Sendable] = [:]
        var diagnostics: [String] = []

        for key in [ALTEntitlementApplicationIdentifier, ALTEntitlementTeamIdentifier, ALTEntitlementGetTaskAllow] {
            if let value = permitted[key] {
                final[key] = value
            }
        }

        if let applicationIdentifier = permitted[ALTEntitlementApplicationIdentifier] as? String {
            let expected = profile.teamIdentifier + "." + bundleIdentifier
            guard wildcard(applicationIdentifier, permits: expected) else {
                throw reconciliationError(
                    "Profile application-identifier '\(applicationIdentifier)' does not permit '\(expected)'."
                )
            }
        } else {
            throw reconciliationError("Provisioning profile has no application-identifier entitlement.")
        }

        guard let teamIdentifier = permitted[ALTEntitlementTeamIdentifier] as? String else {
            throw reconciliationError("Provisioning profile has no team-identifier entitlement.")
        }
        if teamIdentifier != profile.teamIdentifier {
            throw reconciliationError(
                "Profile team entitlement '\(teamIdentifier)' does not match TeamIdentifier '\(profile.teamIdentifier)'."
            )
        }

        for (key, requestedValue) in applicationEntitlements {
            if key == ALTEntitlementApplicationIdentifier ||
                key == ALTEntitlementTeamIdentifier ||
                key == ALTEntitlementGetTaskAllow {
                continue
            }

            if key == ALTEntitlementKeychainAccessGroups {
                guard let requestedGroups = requestedValue as? [String],
                      let permittedGroups = permitted[key] as? [String] else {
                    throw reconciliationError("keychain-access-groups is missing or is not an array of strings.")
                }

                let rewrittenGroups = try requestedGroups.map { group -> String in
                    guard let separator = group.firstIndex(of: ".") else {
                        throw reconciliationError(
                            "Keychain access group '\(group)' does not contain a Team ID prefix."
                        )
                    }
                    return profile.teamIdentifier + group[separator...]
                }

                for group in rewrittenGroups where !permittedGroups.contains(where: { wildcard($0, permits: group) }) {
                    throw reconciliationError(
                        "Provisioning profile does not permit keychain access group '\(group)'."
                    )
                }
                final[key] = rewrittenGroups
                continue
            }

            if key == .appGroups {
                guard let profileGroups = permitted[key] as? [String], !profileGroups.isEmpty else {
                    throw reconciliationError(
                        "Application requests App Groups, but the provisioning profile authorizes none."
                    )
                }
                final[key] = profileGroups
                if !propertyListValuesEqual(requestedValue, profileGroups) {
                    diagnostics.append("Replaced App Groups with the identifiers authorized by the provisioning profile.")
                }
                continue
            }

            guard let permittedValue = permitted[key] else {
                diagnostics.append("Removed unsupported entitlement '\(key.rawValue)'.")
                continue
            }

            if value(permittedValue, permits: requestedValue) {
                // Profiles often express a wider authorization (for example,
                // an array containing "*"). Preserve the app's narrower
                // requested value rather than signing it with the wildcard.
                final[key] = requestedValue
            } else {
                // Some capabilities legitimately change when moving from an
                // App Store signature to a development profile (for example,
                // aps-environment). Use only the value Apple placed in the
                // selected profile and make the transformation diagnostic.
                final[key] = permittedValue
                diagnostics.append("Reconciled entitlement '\(key.rawValue)' to the value authorized by the profile.")
            }
        }

        return ALTEntitlementReconciliationResult(entitlements: final, diagnostics: diagnostics)
    }

    private static func wildcard(_ pattern: String, permits candidate: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            return candidate.hasPrefix(String(pattern.dropLast()))
        }
        return pattern == candidate
    }

    private static func propertyListValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as AnyObject).isEqual(rhs)
    }

    private static func value(_ permitted: Any, permits requested: Any) -> Bool {
        if propertyListValuesEqual(permitted, requested) {
            return true
        }
        if let pattern = permitted as? String, let candidate = requested as? String {
            return wildcard(pattern, permits: candidate)
        }
        if let patterns = permitted as? [String], let candidates = requested as? [String] {
            return candidates.allSatisfy { candidate in
                patterns.contains { wildcard($0, permits: candidate) }
            }
        }
        if let permittedDictionary = permitted as? [String: Any],
           let requestedDictionary = requested as? [String: Any] {
            return requestedDictionary.allSatisfy { key, value in
                guard let permittedValue = permittedDictionary[key] else { return false }
                return self.value(permittedValue, permits: value)
            }
        }
        return false
    }

    private static func reconciliationError(_ reason: String) -> NSError {
        NSError(
            domain: AltSignErrorDomain,
            code: ALTError.invalidApp.rawValue,
            userInfo: [NSLocalizedFailureReasonErrorKey: reason]
        )
    }
}
