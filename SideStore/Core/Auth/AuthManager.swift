//
//  AuthManager.swift
//  SideStore
//
//  Created by Magesh K on 1/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
@preconcurrency import AltSign

public final class AuthManager: @unchecked Sendable {
    public static let shared = AuthManager()
    
    private var portalService: DeveloperPortalAuthService {
        DeveloperPortalService.shared as! DeveloperPortalAuthService
    }
    
    private init() {}
    
    public var team: ALTTeam?
    public var session: ALTAppleAPISession?

    public var isAuthenticated: Bool {
        let hasEmail = Keychain.shared.appleIDEmailAddress != nil
        let hasPassword = Keychain.shared.appleIDPassword != nil
        let hasToken = Keychain.shared.appleIDXcodeToken != nil
        return hasEmail && (hasPassword || hasToken)
    }
    
    public var currentAppleID: String? {
        get { Keychain.shared.appleIDEmailAddress }
        set { Keychain.shared.appleIDEmailAddress = newValue }
    }
    
    public var password: String? {
        get { Keychain.shared.appleIDPassword }
        set { Keychain.shared.appleIDPassword = newValue }
    }
    
    public var adsid: String? {
        get { Keychain.shared.appleIDAdsid }
        set { Keychain.shared.appleIDAdsid = newValue }
    }
    
    public var xcodeToken: String? {
        get { Keychain.shared.appleIDXcodeToken }
        set { Keychain.shared.appleIDXcodeToken = newValue }
    }
    
    public var hasStoredPassword: Bool {
        return Keychain.shared.appleIDPassword != nil
    }
    
    public var hasStoredXcodeToken: Bool {
        return Keychain.shared.appleIDXcodeToken != nil
    }
    
    public func signOut(keepCertificate: Bool = false, keepAnisetteData: Bool = true) {
        self.session = nil
        self.team = nil
        CertificateManager.shared.clearActiveCertificate()
        DatabaseManager.shared.deactivateActiveAccountAndTeam()
        Keychain.shared.reset(keepCertificate: keepCertificate, keepAnisetteData: keepAnisetteData)
    }
    
    @discardableResult
    func authenticate(
        presentingViewController: UIViewController? = nil,
        context: AuthenticatedOperationContext? = nil,
        skipDeviceRegistration: Bool = false,
        skipCertificateProvisioning: Bool = false
    ) async throws -> AuthenticationResult {
        let effectiveContext: AuthenticatedOperationContext
        if let context = context {
            effectiveContext = context
        } else {
            let dbBackgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            let authFlowHandler = AuthFlowHandler(presentingViewController: presentingViewController)
            effectiveContext = AuthenticatedOperationContext(
                authenticationHandler: authFlowHandler,
                anisetteServerHandler: authFlowHandler,
                dbBackgroundContext: dbBackgroundContext
            )
        }
        
        let authOperation = try AuthenticationOperation(
            context: effectiveContext,
            skipDeviceRegistration: skipDeviceRegistration,
            skipCertificateProvisioning: skipCertificateProvisioning
        )
        return try await authOperation.execute()
    }
    
    
    // Developer Portal Operations
    @discardableResult
    public func fetchAccount(session: ALTAppleAPISession) async throws -> ALTAccount {
        return try await self.portalService.fetchAccount(session: session)
    }
    
    public func authenticate(appleID: String, password: String, anisetteData: ALTAnisetteData, xcodeVersion: String, verificationHandler: ((@escaping (String?) -> Void) -> Void)?) async throws -> (ALTAccount, ALTAppleAPISession) {
        return try await self.portalService.authenticate(appleID: appleID, password: password, anisetteData: anisetteData, xcodeVersion: xcodeVersion, verificationHandler: verificationHandler)
    }
    
    public func authenticateWithToken(adsid: String, xcodeToken: String, anisetteData: ALTAnisetteData, xcodeVersion: String) async throws -> (ALTAccount, ALTAppleAPISession) {
        return try await self.portalService.authenticateWithToken(adsid: adsid, xcodeToken: xcodeToken, anisetteData: anisetteData, xcodeVersion: xcodeVersion)
    }
}

fileprivate extension DatabaseManager {
    //TODO: this is not clean, but for now this should be fine, ie we should later make this proper async instead of blocking
    func deactivateActiveAccountAndTeam() {
        let bgContext = self.persistentContainer.newBackgroundContext()
        bgContext.performAndWait {
            if let account = self.activeAccount(in: bgContext) {
                account.isActiveAccount = false
            }
            if let team = self.activeTeam(in: bgContext) {
                team.isActiveTeam = false
            }
            do {
                try bgContext.save()
            } catch {
                debugLog("[AuthManager] Failed to save CoreData context when deactivating active account and team: \(error)")
            }
        }
        
        self.viewContext.performAndWait {
            self.viewContext.processPendingChanges()
            self.viewContext.refreshAllObjects()
        }
    }
}
