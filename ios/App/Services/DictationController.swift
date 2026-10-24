import Foundation
import Speech
import AVFoundation

/// Live dictation into the composer, on both platforms: press the mic,
/// talk, press it again, and the transcript lands in the draft.  Uses the
/// system speech recognizer; nothing is recorded to disk and no audio
/// leaves the device beyond the recognizer itself.
@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var transcript = ""
    @Published public var errorText: String?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()

    public init() {}

    public func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    public func start() {
        guard !isRecording else { return }
        errorText = nil
        transcript = ""
        Task {
            guard await speechAuthorized() else {
                errorText = "Speech recognition is not allowed.  Enable it in Settings, then try again."
                return
            }
            guard await microphoneAuthorized() else {
                errorText = "Microphone access is not allowed.  Enable it in Settings, then try again."
                return
            }
            do {
                try beginRecording()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    public func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func beginRecording() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is unavailable right now."])
        }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        try engine.start()

        self.engine = engine
        self.request = request
        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    private func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private func microphoneAuthorized() async -> Bool {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #else
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        default: return false
        }
        #endif
    }
}
