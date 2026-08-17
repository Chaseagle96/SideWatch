//
//  StandaloneExecutionHandler.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
@preconcurrency import AltSign

protocol AnisetteServerHandler: AnyObject {
    func warnOutdatedAnisetteServer() async throws -> Bool
}

enum ProvisioningErrorDecision {
    case retry
    case cancel
}

protocol AuthenticationHandler: AnyObject {
    func credentials() async throws -> (String, String)
    func verificationCode() async throws -> String?
    func handleSignInResult(_ result: Result<(ALTAccount, ALTAppleAPISession), Error>) async
    
    func resolveTeam(_ teams: [ALTTeam]) async throws -> ALTTeam
    func resolveProvisioningError(_ error: Error) async -> ProvisioningErrorDecision
    func resolvePostAuth() async
    
    func resolveRevocation(certificates: [ALTX509Certificate], teamType: ALTTeamType) async throws -> RevokeDecision
    func resolveResign(mismatchReason: CodeSignValidationReason, context: AuthenticatedOperationContext) async throws -> Bool
    
    func complete() async
}

