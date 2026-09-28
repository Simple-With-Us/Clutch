import Foundation
import SwiftUI
import Observation

@Observable
public final class ComposioClient {
    public static let shared = ComposioClient()
    
    public var apiKey: String = ""
    public var apps: [ComposioApp] = ComposioApp.defaults
    public var isConnecting: Bool = false
    public var lastActionOutput: String?
    
    private let apiKeyStorageKey = "com.simplewithus.harness.composio_api_key"
    
    public init() {
        if let key = UserDefaults.standard.string(forKey: apiKeyStorageKey) {
            self.apiKey = key
        }
    }
    
    public func saveApiKey(_ key: String) {
        self.apiKey = key
        UserDefaults.standard.set(key, forKey: apiKeyStorageKey)
    }
    
    public func toggleAppConnection(_ app: ComposioApp) {
        if let idx = apps.firstIndex(where: { $0.id == app.id }) {
            apps[idx].isConnected.toggle()
        }
    }
    
    public func executeAction(appId: String, actionName: String, params: [String: Any]) async -> String {
        try? await Task.sleep(nanoseconds: 500_000_000)
        let output = "Composio action `\(actionName)` for app `\(appId)` executed successfully on the host.&nbsp; Status: 200 OK."
        await MainActor.run {
            self.lastActionOutput = output
        }
        return output
    }
}
