//
//  Contexts.swift
//  AltStore
//
//  Created by Riley Testut on 6/20/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//


import Foundation
import CoreData
import Network
@preconcurrency import AltSign


enum AlternateIconMode {
    case preserve
    case set(URL)
    case remove
}

fileprivate struct OperationStepItem {
    let step: any OperationStep
    let weight: Int64
    let maxReuse: Int
    let resetProgress: Bool
}

protocol WeightedOperationContext: AnyObject {
    func weightForFirstOccurrence(of step: some OperationStep) -> Int64?
    func weight(for step: some OperationStep, occurrenceNumber: Int) -> Int64?
    func consumeWeight(for step: some OperationStep) throws -> Int64
    func attachProgressSlot(for step: some OperationStep, childProgress: Progress, parentProgress: Progress) throws -> Bool
}

class OperationContext: WeightedOperationContext
{
    var error: Error?
    var dbBackgroundContext: NSManagedObjectContext?

    private var stepItems: [OperationStepItem]
    private var currentIndex = 0
    private var remainingReuses: [Int: Int] = [:]
    private var stepProgressSlots: [Int: Progress] = [:]

    fileprivate init(stepItems: [OperationStepItem] = [], error: Error? = nil, dbBackgroundContext: NSManagedObjectContext? = nil)
    {
        self.stepItems = stepItems
        self.error = error
        self.dbBackgroundContext = dbBackgroundContext
    }

    fileprivate init(context: OperationContext)
    {
        self.stepItems = context.stepItems
        self.currentIndex = context.currentIndex
        self.error = context.error
        self.dbBackgroundContext = context.dbBackgroundContext
        self.remainingReuses = context.remainingReuses
        self.stepProgressSlots = context.stepProgressSlots
    }

    func weightForFirstOccurrence(of step: some OperationStep) -> Int64? {
        weight(for: step, occurrenceNumber: 1)
    }

    func weight(for step: some OperationStep, occurrenceNumber: Int) -> Int64? {
        guard let target = (step as Any) as? AnyHashable else {
            debugLog("[OperationContext] Failed to cast step '\(step)' to AnyHashable")
            return nil
        }
        var matchCount = 0
        for item in stepItems {
            if let itemTarget = (item.step as Any) as? AnyHashable, itemTarget == target {
                matchCount += 1
                if matchCount == occurrenceNumber {
                    return item.weight
                }
            }
        }
        verboseLog("[OperationContext] Weight not found for step '\(step)' (occurrence \(occurrenceNumber))")
        return nil
    }

    private func findIndex(for step: some OperationStep) -> Int? {
        guard let target = (step as Any) as? AnyHashable else { return nil }
        return stepItems.indices[currentIndex...].first(where: {
            guard let itemTarget = (stepItems[$0].step as Any) as? AnyHashable else { return false }
            return itemTarget == target
        })
    }

    @discardableResult
    func consumeWeight(for step: some OperationStep) throws -> Int64 {
        guard let index = findIndex(for: step) else {
            debugLog("[OperationContext] Failed to consume weight for step '\(step)' from index \(currentIndex)")
            throw OperationError.invalidParameters("Missing progress weight for step '\(step)' in steps list")
        }
        
        let item = stepItems[index]
        guard item.maxReuse > 0 else {
            debugLog("[OperationContext] Invalid maxReuse (\(item.maxReuse)) for step '\(step)'")
            throw OperationError.invalidParameters("Invalid maxReuse (\(item.maxReuse)) for step '\(step)' in steps list")
        }
        
        let remaining: Int
        if let existing = remainingReuses[index] {
            remaining = existing
        } else {
            remaining = item.maxReuse
            remainingReuses[index] = remaining
        }
        
        if remaining > 1 {
            remainingReuses[index] = remaining - 1
            return item.weight
        } else {
            // remaining is 1. Clear it completely from the map and advance currentIndex.
            remainingReuses[index] = nil
            currentIndex = index + 1
            purgeCompletedProgressSlots()
            return item.weight
        }
    }

    func attachProgressSlot(for step: some OperationStep, childProgress: Progress, parentProgress: Progress) throws -> Bool {
        guard let index = findIndex(for: step) else { return false }
        let item = stepItems[index]
        guard item.resetProgress else { return false }
        
        let slot: Progress
        if let existing = stepProgressSlots[index] {
            slot = existing
        } else {
            slot = Progress.discreteProgress(totalUnitCount: childProgress.totalUnitCount)
            parentProgress.addChild(slot, withPendingUnitCount: item.weight)
            stepProgressSlots[index] = slot
        }
        
        slot.completedUnitCount = 0
        slot.addChild(childProgress, withPendingUnitCount: childProgress.totalUnitCount)
        try consumeWeight(for: step)
        return true
    }

    private func purgeCompletedProgressSlots() {
        for slotIndex in stepProgressSlots.keys where slotIndex < currentIndex {
            stepProgressSlots[slotIndex] = nil
        }
    }
}

class StandaloneOperationContext: OperationContext
{
    let steps: [StandaloneExecutionStep]

    init(steps: [StandaloneExecutionStep], error: Error? = nil, dbBackgroundContext: NSManagedObjectContext? = nil)
    {
        self.steps = steps
        super.init(stepItems: steps.map { 
                OperationStepItem(
                    step: $0.step, 
                    weight: $0.weight, 
                    maxReuse: $0.maxReuse, 
                    resetProgress: $0.resetProgress
                ) 
            }, 
            error: error, 
            dbBackgroundContext: dbBackgroundContext
        )
    }

    init(context: StandaloneOperationContext)
    {
        self.steps = context.steps
        super.init(context: context)
    }
}

final class AuthenticatedOperationContext: StandaloneOperationContext
{
    var session: ALTAppleAPISession?
    var team: ALTTeam?
    var signingCertificate: ALTCertificate?
    var portalCertificates: [ALTX509Certificate]?

    let authenticationHandler: AuthenticationHandler
    let anisetteServerHandler: AnisetteServerHandler

    init(
        authenticationHandler: AuthenticationHandler,
        anisetteServerHandler: AnisetteServerHandler,
        error: Error? = nil,
        dbBackgroundContext: NSManagedObjectContext? = nil
    ) {
        self.authenticationHandler = authenticationHandler
        self.anisetteServerHandler = anisetteServerHandler
        super.init(steps: .authenticate, error: error, dbBackgroundContext: dbBackgroundContext)
    }

    init(context: AuthenticatedOperationContext) {
        self.authenticationHandler = context.authenticationHandler
        self.anisetteServerHandler = context.anisetteServerHandler
        super.init(context: context)
        self.session = context.session
        self.team = context.team
        self.signingCertificate = context.signingCertificate
        self.portalCertificates = context.portalCertificates
    }
}

class PipelineOperationContext: OperationContext
{
    let pipelineSteps: [PipelineExecutionStep]
    let handler: PipelineExecutionHandler

    init(
        pipelineSteps: [PipelineExecutionStep],
        handler: PipelineExecutionHandler,
        error: Error? = nil,
        dbBackgroundContext: NSManagedObjectContext? = nil
    ) {
        self.pipelineSteps = pipelineSteps
        self.handler = handler
        super.init(stepItems: pipelineSteps.map { 
                OperationStepItem(
                    step: $0.step, 
                    weight: $0.weight, 
                    maxReuse: 1, 
                    resetProgress: false
                ) 
            }, 
            error: error, 
            dbBackgroundContext: dbBackgroundContext
        )
    }

    init(context: PipelineOperationContext)
    {
        self.pipelineSteps = context.pipelineSteps
        self.handler = context.handler
        super.init(context: context)
    }
}

final class SharedPipelineContext: @unchecked Sendable
{
    private let lock = NSLock()
    private var _appIDs: [ALTAppID]?
    private var _appGroups: [ALTAppGroup]?

    var appIDs: [ALTAppID]? {
        get { lock.withLock { _appIDs } }
        set { lock.withLock { _appIDs = newValue } }
    }

    var appGroups: [ALTAppGroup]? {
        get { lock.withLock { _appGroups } }
        set { lock.withLock { _appGroups = newValue } }
    }

    func appendAppID(_ appID: ALTAppID) {
        lock.withLock { _appIDs = (_appIDs ?? []) + [appID] }
    }

    func appendAppGroup(_ appGroup: ALTAppGroup) {
        lock.withLock { _appGroups = (_appGroups ?? []) + [appGroup] }
    }
}

class AppOperationContext: PipelineOperationContext
{
    let bundleIdentifier: String
    var customBundleIdentifier: String?
    var targetAppBundle: ALTApplication?

    var provisioningProfiles: [String: ALTProvisioningProfile]?
    var appexBundleIds: [String: String]?
    var useMainProfile = false
    var isFinished = false

    let authenticatedContext: AuthenticatedOperationContext
    var sharedContext: SharedPipelineContext?

    var overrideCertificate: ALTCertificate?
    var targetCertStatus: CertificateStatus?

    var targetBundleIdentifier: String { customBundleIdentifier ?? bundleIdentifier }

    override var error: Error? {
        get { _error ?? authenticatedContext.error }
        set { _error = newValue
            if authenticatedContext.error == nil
            {
                // Assign newValue to authenticatedContext.error if the latter is nil.
                // This fixes some operations continuing even after an error has occured.
                authenticatedContext.error = newValue
            }
        }
    }
    private var _error: Error?

    init(
        pipelineSteps: [PipelineExecutionStep],
        bundleIdentifier: String,
        authenticatedContext: AuthenticatedOperationContext,
        sharedContext: SharedPipelineContext? = nil,
        handler: PipelineExecutionHandler
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.authenticatedContext = authenticatedContext
        self.sharedContext = sharedContext
        super.init(
            pipelineSteps: pipelineSteps,
            handler: handler,
            error: nil,
            dbBackgroundContext: authenticatedContext.dbBackgroundContext
        )
    }
}

class InstallAppOperationContext: AppOperationContext
{
    lazy var temporaryDirectory: URL = {
        let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        }
        catch { self.error = error }
        return temporaryDirectory
    }()

    var ipaURL: URL?
    var resignedAppBundle: ALTApplication?
    var installedApp: InstalledApp?
    var releaseTrack: ReleaseTrack?
    var additionalEntitlements: [ALTEntitlement: any Sendable] = [:]
    
    var beginInstallationHandler: ((InstalledApp) -> Void)?

    var alternateIconMode: AlternateIconMode = .preserve

    var alternateIconURL: URL? {
        switch self.alternateIconMode {
        case .set(let url):
            return url
        case .preserve:
            if let installedApp = self.installedApp, installedApp.hasAlternateIcon {
                return installedApp.alternateIconURL
            }
            return nil
        case .remove:
            return nil
        }
    }

    var shouldTurnOffData: Bool = false

    // Non-nil when installing from a source.
    @AsyncManaged
    var appVersion: AppVersion?
    
    init(
        pipelineSteps: [PipelineExecutionStep],
        bundleIdentifier: String,
        authenticatedContext: AuthenticatedOperationContext,
        sharedContext: SharedPipelineContext? = nil,
        handler: PipelineExecutionHandler,
        additionalEntitlements: [ALTEntitlement: any Sendable] = [:]
    ){
        super.init(
            pipelineSteps: pipelineSteps,
            bundleIdentifier: bundleIdentifier,
            authenticatedContext: authenticatedContext,
            sharedContext: sharedContext,
            handler: handler
        )
    }

}
