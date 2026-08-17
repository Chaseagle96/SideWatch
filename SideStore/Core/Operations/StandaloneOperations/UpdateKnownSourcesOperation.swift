//
//  UpdateKnownSourcesOperation.swift
//  AltStore
//
//  Created by Riley Testut on 4/13/22.
//  Copyright © 2022 Riley Testut. All rights reserved.
//

import Foundation

private extension URL
{
   static let sources = URL(string: "https://sidestore.io/default-sources")!
}

extension UpdateKnownSourcesOperation
{
    private struct Response: Decodable
    {
        var version: Int
        
        var defaultSources: [KnownSource]?
        var blocked: [KnownSource]?

        private enum CodingKeys: String, CodingKey {
            case version
            case defaultSources = "default"
            case blocked
        }
    }
}

class UpdateKnownSourcesOperation: OperationLogging
{
    private let session: URLSession
    
    init()
    {
        let configuration = URLSessionConfiguration.default
        
        if UserDefaults.standard.responseCachingDisabled
        {
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
        }
        
        self.session = URLSession(configuration: configuration)
    }
    
    func execute() async throws -> ([KnownSource], [KnownSource])
    {
        debugLog("[UpdateKnownSourcesOperation] execute() started")
        defer { debugLog("[UpdateKnownSourcesOperation] execute() completed") }
        let (data, response) = try await self.session.data(from: .sources)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
            throw URLError(.fileDoesNotExist, userInfo: [NSURLErrorKey: URL.sources])
        }
        
        let decoded = try Foundation.JSONDecoder().decode(Response.self, from: data)
        let sources = (defaultSources: decoded.defaultSources ?? [], blocked: decoded.blocked ?? [])
        
        // Cache sources
        UserDefaults.standard.recommendedSources = sources.defaultSources
        UserDefaults.standard.blockedSources = sources.blocked
        
        // Cache default source IDs.
        UserDefaults.standard.defaultSourceIDs = sources.defaultSources.map { $0.identifier }
        
        return sources
    }
}
