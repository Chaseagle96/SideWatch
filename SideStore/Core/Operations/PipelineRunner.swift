//
//  PipelineRunner.swift
//  AltStore
//
//  Created by Magesh K on 8/3/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
@preconcurrency import WidgetKit
@preconcurrency import AltSign


protocol PipelineProgress: Sendable{
    func progress(for operation: AppOperation) -> Progress?
    func set(_ progress: Progress?, for operation: AppOperation)
}
protocol PipelineExecutionContext: AnyObject, Sendable {
    var isActivelyManagingAnyApp: Bool { get }
}
protocol PipelineErrorLogger: AnyObject, Sendable {
    func log(_ error: Error, operation: LoggedError.Operation, app: AppProtocol)
    func getMappedError(for operation: AppOperation, error: Error) -> Error
}


// Pipeline based App Operations
final class PipelineRunner: Sendable
{
    let progress: PipelineProgress
    let context: PipelineExecutionContext
    let logger: PipelineErrorLogger
    let defaultEntitlements: [ALTEntitlement: any Sendable]
    
    init(progress: PipelineProgress,
         context: PipelineExecutionContext,
         logger: PipelineErrorLogger,
         defaultEntitlements: [ALTEntitlement: any Sendable] = [:])
    {
        self.progress = progress
        self.context = context
        self.logger = logger
        self.defaultEntitlements = defaultEntitlements
    }
    
    @discardableResult
    func performSingleOperation(_ operation: AppOperation,
                                handler: PipelineExecutionHandler,
                                context: AuthenticatedOperationContext,
                                completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> RefreshGroup
    {
        let group = RefreshGroup(context: context)
        group.completionHandler = { (results) in
            do
            {
                guard let result = results.values.first else { throw group.context.error ?? OperationError.unknown() }
                let installedApp = try result.get()
                completionHandler(.success(installedApp))
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        debugLog("[AppManager] performSingleOperation started for: \(operation.bundleIdentifier)")
        group.activeTask = Task.detached {
            do {
                debugLog("[AppManager] performSingleOperation executing task for: \(operation.bundleIdentifier)")
                try await self.perform([operation], handler: handler, group: group)
            } catch {
                debugLog("[AppManager] performSingleOperation task failed for: \(operation.bundleIdentifier) with error: \(error)")
                completionHandler(.failure(error))
            }
        }
        
        return group
    }
    
    func performVoidOperation(_ operation: AppOperation,
                              handler: PipelineExecutionHandler,
                              context: AuthenticatedOperationContext,
                              completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        self.performSingleOperation(operation, handler: handler, context: context) { (result) in
            switch result {
            case .success:
                completionHandler(.success(()))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }
    
    @discardableResult
    func perform(_ operations: [AppOperation],
                 handler: PipelineExecutionHandler,
                 group: RefreshGroup) async throws -> RefreshGroup
    {
        let operations = operations.filter { progress.progress(for: $0) == nil || progress.progress(for: $0)?.isCancelled == true }
        guard !operations.isEmpty else { throw OperationError.cancelled }
        
        let backgroundTaskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "com.altstore.AppManager.perform") {
                // Expired
            }
        }
        
        // Disable the idleTimeout
        await MainActor.run {
            if !UIApplication.shared.isIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.isIdleTimeoutDisableEnabled
            }
        }
        
        if group.context.dbBackgroundContext == nil {
            // create a background core-data managedObject context
            group.context.dbBackgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        }
        
        defer {
            group.context.dbBackgroundContext = nil         // Clean up pipeline database context
            for operation in operations {                   // Clean up progress for all operations
                progress.set(nil, for: operation)
            }
            if let error = group.context.error {            // Mark error as-is
                for operation in operations {
                    group.set(.failure(error), forAppWithBundleIdentifier: operation.bundleIdentifier)
                }
            }
            
            
            // Re-enable idleTimeout if no more actions are running and end background task
            Task { @MainActor in
                if UIApplication.shared.isIdleTimerDisabled && !context.isActivelyManagingAnyApp {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }
        
        try await Task.detached {
            /* Minimuxer Readiness Check */
            if let minimuxerError = await getMinimuxerStatus().operationError {
                group.context.error = minimuxerError
                throw minimuxerError
            }
            
            group.progress.completedUnitCount = 1
            
            for operation in operations
            {
                let progress = Progress.discreteProgress(totalUnitCount: 100)
                self.progress.set(progress, for: operation)
                group.progress.addChild(progress, withPendingUnitCount: 100 / Int64(operations.count))
            }
            
            
            /* Authenticate (if necessary) */
            if group.context.session == nil
            {
                do {
                    let result = try await AuthManager.shared.authenticate(
                        context: group.context,
                        skipDeviceRegistration: false
                    )
                    group.context.team = result.team
                    group.context.signingCertificate = result.certificate
                    group.context.session = result.session
                } catch {
                    group.context.error = error
                    throw error
                }
            }
            
            /* Preflight SideStore specific validations */
            let unhandledOperations = operations.filter { operation in
                let isSideStore = (operation.app as? ALTApplication)?.isAltStoreApp == true ||
                                   operation.bundleIdentifier.isAltStoreAppID
                
                if isSideStore {
                    return handler.preflightChecksHandler.isResignActive == true
                }
                return true
            }
            
            do {
                let validateOp = try PreflightChecksOperation(
                    operations: unhandledOperations,
                    handler: handler.preflightChecksHandler,
                    context: group.context
                )
                try await validateOp.execute()
            } catch {
                group.context.error = error
                throw error
            }
            
            
            // run the operation pipeline
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for operation in operations {
                    taskGroup.addTask {
                        try await self.performOperation(for: operation, handler: handler, group: group)
                    }
                }
                while let _ = try await taskGroup.next() {}
            }
            await MainActor.run {
                group.completionHandler?(group.results)
            }
        }.value
        
        return group
    }
    
    func performOperation(for operation: AppOperation, handler: PipelineExecutionHandler, group: RefreshGroup) async throws {
        debugLog("[AppManager] performOperation: Starting execution for app: \(operation.bundleIdentifier)")
        defer{
            // request update view context's in-mem coredata caches (coz we worked so far on bg context)
            DatabaseManager.shared.viewContext.performAndWait {
                DatabaseManager.shared.viewContext.processPendingChanges()
                DatabaseManager.shared.viewContext.refreshAllObjects()
            }
        }
        do {
            let result = try await self.performPipeline(for: operation, handler: handler, group: group)
            progress.set(nil, for: operation)
            debugLog("[AppManager] performOperation: completed successfully. progress was reset for installedApp: \(result.bundleIdentifier)")
            
            // persist the result
            let bundleID = result.bundleIdentifier
            if let dbContext = group.context.dbBackgroundContext {
                do {
                    try dbContext.performAndWait {
                        let hasChanges = dbContext.hasChanges
                        if hasChanges {
                            try dbContext.save()
                        }
                        debugLog("[AppManager] performOperation: Context changes were saved for installedApp: \(bundleID)")
                    }
                } catch {
                    debugLog("[AppManager] perform(): Failed to save InstalledApp to database. \(error.localizedDescription)")
                }
            }
            
            group.set(.success(result), forAppWithBundleIdentifier: bundleID)
            debugLog("[AppManager] performOperation: Execution SUCCESS for app: \(operation.bundleIdentifier)")
            
            if let dbContext = group.context.dbBackgroundContext {
                debugLog("[AppManager] performOperation: Reloading widget timelines...")
                await WidgetDataManager.publishCurrentInstalledApps(in: dbContext)
                debugLog("[AppManager] performOperation: Reloading COMPLETE for widget timelines.")
            }
            
            if result.bundleIdentifier == StoreApp.altstoreAppID {
                let context = StandaloneOperationContext(steps: .scheduleExpirationWarningNotification, dbBackgroundContext: group.context.dbBackgroundContext)
                let scheduleNotifOp = try ScheduleExpirationWarningNotificationOperation(
                    installedApp: result,
                    context: context
                )
                try await scheduleNotifOp.execute()
            }
        } catch {
            progress.set(nil, for: operation)
            
            if Task.isCancelled {
                debugLog("[AppManager] performOperation: Execution CANCELLED for app: \(operation.bundleIdentifier)")
            } else {
                debugLog("[AppManager] performOperation: Execution FAILED for app: \(operation.bundleIdentifier) with error: \(error.localizedDescription)")
            }
            
            let mappedError = logger.getMappedError(for: operation, error: error)
            
            logger.log(error, operation: operation.loggedErrorOperation, app: operation.app)
            
            group.set(.failure(mappedError), forAppWithBundleIdentifier: operation.bundleIdentifier)
        }
    }
    
    private func performPipeline(for operation: AppOperation, handler: PipelineExecutionHandler, group: RefreshGroup) async throws -> InstalledApp
    {
        let pipelineSteps = PipelineStepDefinition.steps(for: operation)
        let context = InstallAppOperationContext(
            pipelineSteps: pipelineSteps,
            bundleIdentifier: operation.bundleIdentifier,
            authenticatedContext: group.context,
            sharedContext: group.sharedContext,
            handler: handler,
            additionalEntitlements: defaultEntitlements
        )
        
        if case .install(_, let customID) = operation { context.customBundleIdentifier  = customID }
        if case .update(_,  let customID) = operation { context.customBundleIdentifier  = customID }
        if case .resign(_,  let mode)     = operation { context.alternateIconMode       = mode }
        
        if let app = operation.app as? InstalledApp {
            context.targetAppBundle = ALTApplication(fileURL: app.fileURL)
            context.useMainProfile = app.useMainProfile
            context.customBundleIdentifier = app.customBundleIdentifier
            context.installedApp = app
        }
        
        context.beginInstallationHandler = { (installedApp) in
            group.beginInstallationHandler?(installedApp)
        }
        
        var downloadingApp = operation.app
        if let installedApp = operation.app as? InstalledApp {
            if case .resign = operation { downloadingApp = installedApp }
            else if let storeApp = installedApp.storeApp, !FileManager.default.fileExists(atPath: installedApp.fileURL.path) {
                downloadingApp = storeApp
            }
        }
        
        let permissionReviewMode: PermissionReviewMode
        switch operation {
            case .install: permissionReviewMode = .all
            case .update: permissionReviewMode = .added
            default: permissionReviewMode = .none
        }
        
        let permissionsMode = UserDefaults.standard.permissionCheckingDisabled ? .none : permissionReviewMode
        let operationProgress = progress.progress(for: operation)
        return try await PipelineExecutor.shared.executePipeline(
            steps: pipelineSteps,
            context: context,
            operation: operation,
            group: group,
            downloadingApp: downloadingApp,
            permissionsMode: permissionsMode,
            operationProgress: operationProgress
        )
    }
}


