//
//  DeveloperPortalService.swift
//  SideStore
//
//  Created by Magesh K on 2026-06-29.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
@preconcurrency import AltSign

enum DeveloperPortalError: LocalizedError {
    case missingAccount
    case missingSession
    case noTeams(appleID: String)
    case noCertificates(teamName: String)
    case missingCertificate(machineName: String)
    case revocationFailed(serialNumber: String)
    case noDevices(teamName: String)
    case deviceRegistrationFailed(name: String, identifier: String)
    
    var errorDescription: String? {
        switch self {
        case .missingAccount:
            return NSLocalizedString("Authentication failed: Account was nil after authentication.", comment: "")
        case .missingSession:
            return NSLocalizedString("Authentication failed: Session was nil after authentication.", comment: "")
        case .noTeams(let appleID):
            return String(format: NSLocalizedString("Failed to fetch teams: No developer teams were returned for account '%@'.", comment: ""), appleID)
        case .noCertificates(let teamName):
            return String(format: NSLocalizedString("Failed to fetch certificates: Response contained no certificates for team '%@'.", comment: ""), teamName)
        case .missingCertificate(let machineName):
            return String(format: NSLocalizedString("Failed to create certificate: Certificate response was nil for machine '%@'.", comment: ""), machineName)
        case .revocationFailed(let serialNumber):
            return String(format: NSLocalizedString("Failed to revoke certificate '%@': Revocation failed.", comment: ""), serialNumber)
        case .noDevices(let teamName):
            return String(format: NSLocalizedString("Failed to fetch devices: No devices returned for team '%@'.", comment: ""), teamName)
        case .deviceRegistrationFailed(let name, let identifier):
            return String(format: NSLocalizedString("Failed to register device '%@' (%@): Device response was nil.", comment: ""), name, identifier)
        }
    }
}

public class DeveloperPortalService {
    public static let shared: DeveloperPortalService = DeveloperPortalAuthService()
    
    fileprivate init() {}
    
    public func fetchTeams(for account: ALTAccount, session: ALTAppleAPISession) async throws -> [ALTTeam] {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchTeams(for: account, session: session) { (teams, err) in
                if let teams = teams {
                    continuation.resume(returning: teams)
                } else if let err = err {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume(throwing: DeveloperPortalError.noTeams(appleID: account.appleID))
                }
            }
        }
    }
    
    public func fetchCertificates(team: ALTTeam, session: ALTAppleAPISession) async throws -> [ALTX509Certificate] {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchCertificates(for: team, session: session) { certs, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let certs = certs {
                    continuation.resume(returning: certs)
                } else {
                    continuation.resume(throwing: DeveloperPortalError.noCertificates(teamName: team.name))
                }
            }
        }
    }
    
    public func createCertificate(machineName: String, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.addCertificate(machineName: machineName, to: team, session: session) { cert, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let cert = cert {
                    continuation.resume(returning: cert)
                } else {
                    continuation.resume(throwing: DeveloperPortalError.missingCertificate(machineName: machineName))
                }
            }
        }
    }
    
    public func revokeCertificate(_ certificate: ALTX509Certificate, team: ALTTeam, session: ALTAppleAPISession) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.revoke(certificate, for: team, session: session) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(throwing: DeveloperPortalError.revocationFailed(serialNumber: certificate.serialNumber))
                }
            }
        }
    }
    
    public func fetchDevices(for team: ALTTeam, types: ALTDeviceType, session: ALTAppleAPISession) async throws -> [ALTDevice] {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchDevices(for: team, types: types, session: session) { (devices, err) in
                if let devices = devices {
                    continuation.resume(returning: devices)
                } else if let err = err {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume(throwing: DeveloperPortalError.noDevices(teamName: team.name))
                }
            }
        }
    }
    
    public func registerDevice(name: String, identifier: String, type: ALTDeviceType, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTDevice {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.registerDevice(name: name, identifier: identifier, type: type, team: team, session: session) { (device, err) in
                if let device = device {
                    continuation.resume(returning: device)
                } else if let err = err {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume(throwing: DeveloperPortalError.deviceRegistrationFailed(name: name, identifier: identifier))
                }
            }
        }
    }
}

class DeveloperPortalAuthService: DeveloperPortalService {
    fileprivate override init() {
        super.init()
    }

    func fetchAccount(session: ALTAppleAPISession) async throws -> ALTAccount {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.fetchAccount(session: session) { result in
                continuation.resume(with: result)
            }
        }
    }

    func authenticate(appleID: String, password: String, anisetteData: ALTAnisetteData, xcodeVersion: String, verificationHandler: ((@escaping (String?) -> Void) -> Void)?) async throws -> (ALTAccount, ALTAppleAPISession) {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.authenticate(appleID: appleID, password: password, anisetteData: anisetteData, xcodeVersion: xcodeVersion, verificationHandler: verificationHandler) { (account, session, error) in
                if let account = account, let session = session {
                    continuation.resume(returning: (account, session))
                } else if let error = error {
                    continuation.resume(throwing: error)
                } else if account == nil {
                    continuation.resume(throwing: DeveloperPortalError.missingAccount)
                } else {
                    continuation.resume(throwing: DeveloperPortalError.missingSession)
                }
            }
        }
    }
    
    func authenticateWithToken(adsid: String, xcodeToken: String, anisetteData: ALTAnisetteData, xcodeVersion: String) async throws -> (ALTAccount, ALTAppleAPISession) {
        let session = ALTAppleAPISession(dsid: adsid, authToken: xcodeToken, anisetteData: anisetteData, xcodeVersion: xcodeVersion)
        let account = try await fetchAccount(session: session)
        return (account, session)
    }
}
