//
//  APIServiceManager.swift
//  SnapiExampleApp
//
//  Created by Asif Newaz on 21.03.26.
//  Copyright © 2026 Example. All rights reserved.
//

import Foundation
import Snapi

final class APIServiceManager {
 
    static let shared = APIServiceManager()
 
    let configuration: NetworkConfiguration
    let client: APIClient
 
    private init() {
        let logger = NetworkLogger(isEnabled: true, level: .basic)

        configuration = NetworkConfiguration(
            baseURL: "https://jsonplaceholder.typicode.com",
            timeout: 30
        )
        client = APIClient(configuration: configuration, logger: logger)
        client.logger.isEnabled = true
    }
 
    /// Called after login — injects token globally for all future requests.
    func setAuthToken(_ token: String) {
        configuration.setTokenHeader("Basic")
        configuration.setDefaultHeader("Basic \(token)", forKey: "Authorization")
        configuration.setAuthToken("Basic \(token)")
    }
 
    /// Called after login — injects token globally for all future requests.
    func setBaseURL(_ url: URL) {
        configuration.updateBaseURL(url)
    }
 
    /// Called on logout — strips token from all future requests.
    func clearAuthToken() {
        configuration.removeDefaultHeader(forKey: "Authorization")
    }
    

}
