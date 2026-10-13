import Foundation
import Observation
import UIKit
import CometChatUIKitSwift
import CometChatSDK
import CometChatCardsSwift

/// Coordinates the CometChat-backed Chat tab: fetches the app coordinates
/// from the Mac sidecar (`GET /clutch/v1/chat-config`, chat-token gated),
/// initializes the UI Kit once, logs this device in, and resolves the agent
/// user the thread renders.  Auth Key travel is dev-grade for this try;
/// server-minted user tokens are the follow-up hardening.
@MainActor
@Observable
public final class CometChatManager {
    public static let shared = CometChatManager()

    public enum Phase: Equatable {
        case idle
        case loadingConfig
        case signingIn
        case ready
        case failed(String)
    }

    public var phase: Phase = .idle
    public var agentUser: CometChatSDK.User?
    public var myUid: String?
    public var agentUid: String = "clutch-agent"

    @ObservationIgnored private var configuredAppId: String?
    @ObservationIgnored private var cardListenerAdded = false

    public init() {}

    /// Stable per-device UID so the 1:1 thread (device ↔ agent) is the same
    /// across launches without any signup screen.
    public func deviceUid() -> String {
        let vendor = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        return "clutch-ios-\(vendor.prefix(8).lowercased())"
    }

    /// Idempotent: safe to call on every appearance of the Chat tab.
    public func prepare(host: ClutchHost) async {
        guard phase != .loadingConfig && phase != .signingIn else { return }
        guard let chatToken = host.chatToken, !chatToken.isEmpty else {
            phase = .failed("Pair again to enable native chat — this host has no chat token yet.")
            return
        }
        phase = .loadingConfig
        do {
            let config = try await fetchConfig(host: host, token: chatToken)
            try await ensureInitialized(config: config)
            try await ensureLoggedIn()
            try await ensureAgentUser()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Steps

    private struct ChatConfigResponse: Decodable {
        struct CometChat: Decodable {
            var appId: String
            var region: String
            var authKey: String
            var agentUid: String?
        }
        var cometchat: CometChat?
    }

    private struct FetchedConfig {
        var appId: String
        var region: String
        var authKey: String
        var agentUid: String
    }

    private func fetchConfig(host: ClutchHost, token: String) async throws -> FetchedConfig {
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        comps.path = "/clutch/v1/chat-config"
        guard let url = comps.url else { throw CometChatSetupError.badHost }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let status = (resp as? HTTPURLResponse)?.statusCode else { throw CometChatSetupError.configUnavailable }
        if status == 401 { throw CometChatSetupError.tokenRejected }
        guard status == 200 else { throw CometChatSetupError.configUnavailable }
        let decoded = try JSONDecoder().decode(ChatConfigResponse.self, from: data)
        guard let cc = decoded.cometchat else { throw CometChatSetupError.notConfigured }
        return FetchedConfig(appId: cc.appId, region: cc.region, authKey: cc.authKey, agentUid: cc.agentUid ?? "clutch-agent")
    }

    private func ensureInitialized(config: FetchedConfig) async throws {
        agentUid = config.agentUid
        if configuredAppId == config.appId, CometChat.getLoggedInUser() != nil { return }
        let settings = UIKitSettings()
        settings
            .set(appID: config.appId)
            .set(authKey: config.authKey)
            .set(region: config.region)
            .subscribePresenceForAllUsers()
            .enable(inAppIncomingCall: false)
            .build()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            CometChatUIKit.init(uiKitSettings: settings) { result in
                switch result {
                case .success:
                    CometChat.setSource(resource: "uikit-v5", platform: "ios", language: "swift")
                    cont.resume()
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
        configuredAppId = config.appId
    }

    private func ensureLoggedIn() async throws {
        let uid = deviceUid()
        if CometChat.getLoggedInUser()?.uid == uid {
            myUid = uid
            return
        }
        // A reinstall changes the vendor id while the SDK may still hold the
        // previous session: log that user out before logging this device in.
        if CometChat.getLoggedInUser() != nil {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                CometChat.logout { _ in
                    cont.resume()
                } onError: { _ in
                    cont.resume()
                }
            }
        }
        phase = .signingIn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            CometChatUIKit.login(uid: uid) { result in
                switch result {
                case .success:
                    cont.resume()
                case .onError(let error):
                    cont.resume(throwing: CometChatSetupError.loginFailed(error.errorDescription))
                @unknown default:
                    cont.resume(throwing: CometChatSetupError.loginFailed("Login failed."))
                }
            }
        }
        myUid = uid
        if !cardListenerAdded {
            cardListenerAdded = true
            CometChatCardEvents.addListener("clutch-card-listener", ClutchCardHandler.shared)
        }
    }

    private func ensureAgentUser() async throws {
        if agentUser?.uid == agentUid { return }
        let user: CometChatSDK.User = try await withCheckedThrowingContinuation { cont in
            CometChat.getUser(UID: agentUid) { fetched in
                if let fetched {
                    cont.resume(returning: fetched)
                } else {
                    cont.resume(throwing: CometChatSetupError.agentMissing)
                }
            } onError: { _ in
                cont.resume(throwing: CometChatSetupError.agentMissing)
            }
        }
        agentUser = user
    }
}

public enum CometChatSetupError: Error, LocalizedError {
    case badHost
    case configUnavailable
    case tokenRejected
    case notConfigured
    case agentMissing
    case loginFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badHost:
            return "This host has no usable chat address."
        case .configUnavailable:
            return "The Mac did not answer chat-config — is the chat bridge running (pm2 clutch-web)?"
        case .tokenRejected:
            return "The Mac rejected this chat token — pair again to refresh it."
        case .notConfigured:
            return "CometChat is not configured on the Mac yet."
        case .agentMissing:
            return "The clutch-agent user does not exist in the CometChat app yet."
        case .loginFailed(let detail):
            return "Chat login failed: \(detail)"
        }
    }
}

/// Card taps surface as a notification the SwiftUI tab turns into an alert.
extension Notification.Name {
    static let clutchCardAction = Notification.Name("codes.clutch.cardAction")
}

final class ClutchCardHandler: CometChatCardEventListener {
    static let shared = ClutchCardHandler()
    private init() {}

    func ccCardActionClicked(message: BaseMessage, action: CometChatCardActionEvent) {
        NotificationCenter.default.post(
            name: .clutchCardAction,
            object: nil,
            userInfo: ["title": action.action ?? action.elementId ?? "Card action"]
        )
    }
}
