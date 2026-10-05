import Foundation

/// Pluggable audio transcription service supporting local host whisper.cpp
/// and cloud OpenRouter Whisper API.
public final class TranscriptionService {
    public static let shared = TranscriptionService()

    public enum TranscriptionMode: String, CaseIterable, Codable {
        case auto = "Auto (Host First, Cloud Fallback)"
        case hostOnly = "Host Local Whisper (whisper.cpp)"
        case cloudOnly = "OpenRouter Whisper (Cloud)"
    }

    private let modeKey = "codes.clutch.transcription_mode"
    private let openRouterKeyPref = "codes.clutch.openrouter_key"

    public var mode: TranscriptionMode {
        get {
            if let saved = UserDefaults.standard.string(forKey: modeKey),
               let mode = TranscriptionMode(rawValue: saved) {
                return mode
            }
            return .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
        }
    }

    public var openRouterApiKey: String {
        get {
            UserDefaults.standard.string(forKey: openRouterKeyPref) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: openRouterKeyPref)
        }
    }

    private init() {}

    /// Transcribes an audio recording file at the given local file URL.
    public func transcribeAudio(fileURL: URL, hostURL: URL?) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "TranscriptionService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Audio recording file not found at \(fileURL.path)."])
        }

        let audioData = try Data(contentsOf: fileURL)

        switch mode {
        case .hostOnly:
            guard let hostURL = hostURL else {
                throw NSError(domain: "TranscriptionService", code: 400, userInfo: [NSLocalizedDescriptionKey: "No active host connected for local transcription."])
            }
            return try await transcribeViaHost(audioData: audioData, hostURL: hostURL)

        case .cloudOnly:
            return try await transcribeViaOpenRouter(audioData: audioData)

        case .auto:
            if let hostURL = hostURL {
                do {
                    return try await transcribeViaHost(audioData: audioData, hostURL: hostURL)
                } catch {
                    if !openRouterApiKey.isEmpty {
                        return try await transcribeViaOpenRouter(audioData: audioData)
                    }
                    throw error
                }
            } else if !openRouterApiKey.isEmpty {
                return try await transcribeViaOpenRouter(audioData: audioData)
            } else {
                throw NSError(domain: "TranscriptionService", code: 503, userInfo: [NSLocalizedDescriptionKey: "Host offline and no OpenRouter API key configured.  Connect a host or add an API key in Settings."])
            }
        }
    }

    private func transcribeViaHost(audioData: Data, hostURL: URL) async throws -> String {
        let endpoint = hostURL.appendingPathComponent("v1/audio/transcriptions")
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TranscriptionService", code: status, userInfo: [NSLocalizedDescriptionKey: "Host transcription returned HTTP \(status): \(errBody)"])
        }

        struct TranscriptionResponse: Codable {
            let text: String
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeViaOpenRouter(audioData: Data) async throws -> String {
        guard !openRouterApiKey.isEmpty else {
            throw NSError(domain: "TranscriptionService", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenRouter API key is missing.  Please enter it in Settings to transcribe in the cloud."])
        }

        guard let url = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions") else {
            throw NSError(domain: "TranscriptionService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenRouter URL."])
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(openRouterApiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("openai/whisper-large-v3\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TranscriptionService", code: status, userInfo: [NSLocalizedDescriptionKey: "OpenRouter transcription returned HTTP \(status): \(errBody)"])
        }

        struct TranscriptionResponse: Codable {
            let text: String
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
