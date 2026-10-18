import Foundation
import Observation

/// Client for the sidecar's Infisical settings endpoint
/// (`GET`/`PUT /clutch/v1/infisical`, see `src/web/infisical-route.ts`).
///
/// Same chat-token gate and host addressing as the session endpoints, so the
/// pairing a device already has is all the authorization this panel needs: the
/// bearer token never leaves the device and never reaches a log here.
///
/// A client secret passed to `saveIdentity` is forwarded once and dropped.  It
/// is never logged, never put in an error message, and never read back — the
/// server answers with `hasClientSecret` and a client-id hint instead.
public struct InfisicalSettingsClient {
    public var host: ClutchHost

    public init(host: ClutchHost) {
        self.host = host
    }

    private static let path = "/clutch/v1/infisical"

    /// Reads the redacted identity summary and the managed-key inventory.
    public func fetch() async throws -> InfisicalSettingsSnapshot {
        let request = try authorized(url())
        let (data, response) = try await send(request)
        try requireSuccess(response, data: data)
        return try decodeSnapshot(data)
    }

    /// Saves the machine identity to `$CLUTCH_HOME/infisical.json`.  An empty
    /// `clientSecret` keeps the stored secret; the Mac merges it.
    @discardableResult
    public func saveIdentity(
        projectId: String,
        clientId: String,
        clientSecret: String
    ) async throws -> InfisicalSettingsSnapshot {
        // Built as a dictionary so an omitted-or-empty secret is simply absent
        // rather than a value the Mac might take literally.
        var identity: [String: String] = ["projectId": projectId, "clientId": clientId]
        if !clientSecret.isEmpty { identity["clientSecret"] = clientSecret }
        return try await put(["identity": identity])
    }

    /// Writes one managed setting through to Infisical.
    @discardableResult
    public func saveSetting(key: String, value: String) async throws -> InfisicalSettingsSnapshot {
        try await put(["setting": ["key": key, "value": value]])
    }

    // MARK: - Transport

    private func put(_ body: [String: Any]) async throws -> InfisicalSettingsSnapshot {
        var request = try authorized(url())
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw InfisicalSettingsError.transport("The app couldn't encode the request.")
        }
        let (data, response) = try await send(request)
        try requireSuccess(response, data: data)
        return try decodeSnapshot(data)
    }

    private func url() throws -> URL {
        var comps = URLComponents()
        comps.scheme = host.origin.scheme
        comps.host = host.origin.host
        comps.port = host.chatPort
        comps.path = Self.path
        guard let url = comps.url else { throw InfisicalSettingsError.badHost }
        return url
    }

    private func authorized(_ url: URL, timeout: TimeInterval = 30) throws -> URLRequest {
        guard let token = host.chatToken, !token.isEmpty else { throw InfisicalSettingsError.missingToken }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // A setting write goes out to Infisical and back, so the budget is the
        // sidecar's, not the app's; the session client runs longer still.
        request.timeoutInterval = timeout
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            // The URL can name the host; the token and any payload cannot reach
            // this string, because neither is part of a transport error.
            throw InfisicalSettingsError.transport(error.localizedDescription)
        }
    }

    private func requireSuccess(_ response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw Self.failure(status: status, data: data) }
    }

    private func decodeSnapshot(_ data: Data) throws -> InfisicalSettingsSnapshot {
        guard let snapshot = try? JSONDecoder().decode(InfisicalSettingsSnapshot.self, from: data) else {
            throw InfisicalSettingsError.unreadablePayload
        }
        return snapshot
    }

    /// Maps a non-200 answer onto a reportable failure, preferring the Mac's own
    /// `error` text.
    private static func failure(status: Int, data: Data) -> InfisicalSettingsError {
        struct ServerError: Decodable {
            var error: String?
            var key: String?
        }
        let serverError = try? JSONDecoder().decode(ServerError.self, from: data)
        let reason = serverError?.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch status {
        case 400:
            return .rejected(reason: reason.isEmpty ? "The Mac rejected the request." : reason)
        case 401:
            return .unauthorized
        case 403:
            return .untrustedHost
        case 409:
            return .restartRequired(reason: reason.isEmpty ? "Clutch must restart on the Mac first." : reason)
        case 503:
            return .notConfigured(key: serverError?.key ?? "", reason: reason)
        default:
            return .rejected(reason: reason.isEmpty ? "The Mac's chat sidecar answered \(status)." : reason)
        }
    }
}

/// Load and save state for the Infisical section of the settings sheet.
///
/// Kept out of the view so the section stays presentation only: it reads this
/// model's published state and calls its three actions.  Every write here
/// either applies the state the server returned or sets an error — there is no
/// path that reports success without the Mac having said so.
@MainActor
@Observable
final class InfisicalSettingsModel {
    private(set) var snapshot: InfisicalSettingsSnapshot?
    private(set) var isLoading = false
    private(set) var isSavingIdentity = false
    private(set) var isSavingSetting = false
    /// Set when the first load failed and there is nothing to show yet.
    private(set) var loadErrorText: String?
    /// Set by the most recent save that failed.
    private(set) var actionErrorText: String?
    private(set) var statusText: String?
    /// True once an identity save came back needing a restart.  Managed-setting
    /// writes stay blocked until the operator reloads after restarting the Mac,
    /// because the running process is still holding the old credentials.
    private(set) var needsRestart = false

    // Machine identity editor.  The secret is only ever what the operator just
    // typed; it is cleared as soon as it has been saved.
    var projectId = ""
    var clientId = ""
    var clientSecret = ""

    // Managed setting editor.
    var selectedKey = ""
    var settingValue = ""

    private let host: ClutchHost?

    init(host: ClutchHost?) {
        self.host = host
    }

    // MARK: - Derived state

    var hasHost: Bool {
        guard let host else { return false }
        guard let token = host.chatToken else { return false }
        return !token.isEmpty
    }

    var identity: InfisicalIdentity? { snapshot?.identity }

    var hasStoredClientSecret: Bool { identity?.hasClientSecret ?? false }

    var selectedSetting: InfisicalManagedKey? {
        guard let keys = snapshot?.keys else { return nil }
        return keys.first { $0.key == selectedKey }
    }

    var isIdentityDirty: Bool {
        guard let identity else { return !(projectId.isEmpty && clientId.isEmpty && clientSecret.isEmpty) }
        return projectId.trimmed != identity.projectId
            || clientId.trimmed != identity.clientId
            || !clientSecret.trimmed.isEmpty
    }

    /// The Mac merges an empty secret, so this only needs a new one when there
    /// is no stored secret to keep.
    var canSaveIdentity: Bool {
        guard !isSavingIdentity, identity != nil else { return false }
        guard !projectId.trimmed.isEmpty, !clientId.trimmed.isEmpty else { return false }
        if clientSecret.trimmed.isEmpty && !hasStoredClientSecret { return false }
        return isIdentityDirty
    }

    var canSaveSetting: Bool {
        guard !isSavingSetting, !needsRestart, let entry = selectedSetting else { return false }
        // An empty secret is a real value to the Mac, not a no-op, so saving one
        // would wipe the key.  A non-secret may be cleared deliberately.
        if entry.kind == .secret && settingValue.trimmed.isEmpty { return false }
        return !settingValue.isEmpty || entry.kind != .secret
    }

    var clientSecretPlaceholder: String {
        hasStoredClientSecret ? "Saved — Enter to Replace" : "Enter Client Secret"
    }

    func secretValuePlaceholder(for entry: InfisicalManagedKey) -> String {
        entry.isSet ? "Saved — Enter to Replace" : "Enter a Value"
    }

    // MARK: - Actions

    /// First load only; a reload is always explicit so an in-progress edit is
    /// never overwritten by a background refresh.
    func loadIfNeeded() async {
        guard snapshot == nil, loadErrorText == nil, hasHost else { return }
        await load()
    }

    func load() async {
        guard hasHost, !isLoading else { return }
        isLoading = true
        loadErrorText = nil
        defer { isLoading = false }
        do {
            let snapshot = try await InfisicalSettingsClient(host: host!).fetch()
            loadErrorText = nil
            apply(snapshot, replaceEditor: true)
        } catch {
            snapshot = nil
            loadErrorText = Self.message(for: error)
        }
    }

    /// Operator-driven refresh, also the way to clear the restart notice once
    /// Clutch has been restarted on the Mac.  Only the operator can know that,
    /// so the panel never assumes it happened.
    func reload() async {
        needsRestart = false
        statusText = nil
        actionErrorText = nil
        await load()
    }

    func saveIdentity() async {
        guard hasHost, canSaveIdentity else { return }
        isSavingIdentity = true
        actionErrorText = nil
        statusText = nil
        defer { isSavingIdentity = false }
        do {
            let snapshot = try await InfisicalSettingsClient(host: host!).saveIdentity(
                projectId: projectId.trimmed,
                clientId: clientId.trimmed,
                clientSecret: clientSecret.trimmed
            )
            // The secret now lives on the Mac; keep no copy of it here.
            clientSecret = ""
            apply(snapshot, replaceEditor: false)
            needsRestart = snapshot.restartRequired
            statusText = snapshot.restartRequired
                ? Copy.gap("Machine identity saved on the Mac.", "Clutch must restart there to use the new credentials.")
                : "Machine identity saved on the Mac."
        } catch {
            actionErrorText = Self.message(for: error)
        }
    }

    func saveSetting() async {
        guard hasHost, let entry = selectedSetting, canSaveSetting else { return }
        isSavingSetting = true
        actionErrorText = nil
        statusText = nil
        defer { isSavingSetting = false }
        do {
            let snapshot = try await InfisicalSettingsClient(host: host!).saveSetting(
                key: entry.key,
                value: settingValue.trimmed
            )
            apply(snapshot, replaceEditor: false)
            statusText = snapshot.source == .infisical
                ? "\(entry.key) saved to Infisical."
                : Copy.gap("\(entry.key) saved.", "This Mac is reading settings from an environment seed.")
        } catch {
            actionErrorText = Self.message(for: error)
        }
    }

    /// Re-points the editor at another key.  A secret's field starts empty and
    /// says so; a plain key starts from the value the Mac reported.
    func selectSetting(_ key: String) {
        selectedKey = key
        guard let entry = selectedSetting else {
            settingValue = ""
            return
        }
        settingValue = entry.displayValue
    }

    // MARK: - Internals

    private func apply(_ snapshot: InfisicalSettingsSnapshot, replaceEditor: Bool) {
        self.snapshot = snapshot

        if replaceEditor {
            projectId = snapshot.identity.projectId
            clientId = snapshot.identity.clientId
        }

        let keys = snapshot.keys
        if !keys.contains(where: { $0.key == selectedKey }) {
            // Prefer a plain key: the first secret would open on an empty field.
            selectedKey = (keys.first { $0.kind.showsStoredValue } ?? keys.first)?.key ?? ""
        }
        if replaceEditor || settingValue.isEmpty {
            settingValue = selectedSetting?.displayValue ?? ""
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// File-scoped so the trim rule the Mac applies (`str()` trims) has exactly
/// one implementation here.
private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}