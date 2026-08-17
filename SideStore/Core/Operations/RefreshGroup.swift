//
//  RefreshGroup.swift
//  AltStore
//
//  Created by Riley Testut on 6/20/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import CoreData
@preconcurrency import AltSign

final class RefreshGroup: NSObject
{
    let context: AuthenticatedOperationContext
    let sharedContext: SharedPipelineContext
    let progress = Progress.discreteProgress(totalUnitCount: 100)
    
    var completionHandler: (([String: Result<InstalledApp, Error>]) -> Void)?
    var beginInstallationHandler: ((InstalledApp) -> Void)?
        
    private(set) var results = [String: Result<InstalledApp, Error>]()
    
    // Keep strong references to managed object contexts
    // so they don't die out from under us.
    private(set) var _contexts = Set<NSManagedObjectContext>()
    
    var activeTask: Task<Void, Never>?
    private let lock = NSLock()
    
    init(context: AuthenticatedOperationContext, sharedContext: SharedPipelineContext = SharedPipelineContext())
    {
        self.context = context
        self.sharedContext = sharedContext
        super.init()
    }
    
    func set(_ result: Result<InstalledApp, Error>, forAppWithBundleIdentifier bundleIdentifier: String)
    {
        self.lock.withLock {
            self.results[bundleIdentifier] = result
            
            switch result
            {
            case .failure: break
            case .success(let installedApp):
                guard let context = installedApp.managedObjectContext else { break }
                self._contexts.insert(context)
            }
        }
    }
    
    func cancel()
    {
        self.activeTask?.cancel()
    }
}
