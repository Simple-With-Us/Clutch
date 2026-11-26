import SwiftUI
import UniformTypeIdentifiers

/// Native input bar for the Mac chat surface
struct MacChatInputBar: View {
    @Binding var draft: String
    var sending: Bool
    var onSend: () -> Void
    var onStop: () -> Void
    var onQueue: () -> Void
    var onSteer: () -> Void
    var canSteer: Bool = false
    var isSteering: Bool = false
    var isDictating: Bool = false
    var onMic: () -> Void = {}
    var attachments: [ChatAttachment] = []
    var onAttach: () -> Void = {}
    var onRemoveAttachment: (ChatAttachment) -> Void = { _ in }
    var onPaste: () -> Void = {}
    var onProviders: ([NSItemProvider]) -> Void = { _ in }
    @State private var isDropTargeted = false

    @AppStorage(MacBusySendMode.storageKey)
    private var busySendModeRawValue = MacBusySendMode.defaultMode.rawValue

    private var busySendMode: MacBusySendMode {
        let preferred = MacBusySendMode(rawValue: busySendModeRawValue) ?? .queue
        return preferred == .steer && !canSteer ? .queue : preferred
    }

    var body: some View {
        VStack(spacing: 4) {
            if !attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                                .font(.system(size: 10))
                            Text(attachment.displayName)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Button {
                                onRemoveAttachment(attachment)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(attachment.displayName)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.clutchSecondaryBackground, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: onMic) {
                    Image(systemName: isDictating ? "mic.fill" : "mic")
                        .font(.system(size: 15))
                        .foregroundStyle(isDictating ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDictating ? "Stop Dictation" : "Dictate")
                .help(isDictating ? "Stop Dictation" : "Dictate A Message")

                Button(action: onAttach) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach File")
                .help("Attach A File")

                Button(action: onPaste) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste Image Or File")
                .help("Paste An Image Or A File")

                TextField("Message The Agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                    .accessibilityIdentifier("message-draft")
                    .help(sending ? "Write your next message while the agent works" : "Message The Agent")
                    .onSubmit(sendUsingDefaultAction)

                if sending {
                    Button(action: sendUsingDefaultAction) {
                        Label(busySendMode.title, systemImage: busySendMode.symbol)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (busySendMode == .steer && isSteering))
                    .accessibilityLabel("\(busySendMode.title) Message")
                    .help(busySendMode.explanation)
                    .keyboardShortcut(.return, modifiers: .command)

                    Menu {
                        Button {
                            onQueue()
                        } label: {
                            Label("Queue Message", systemImage: MacBusySendMode.queue.symbol)
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button {
                            onSteer()
                        } label: {
                            Label("Steer Current Turn", systemImage: MacBusySendMode.steer.symbol)
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSteer || isSteering)
                        .help(steerHelp)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20))
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Choose How To Send")
                    .help("Queue this message or steer the current turn")

                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                    .help("Stop This Turn")
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send Message")
                    .help("Send (Return)")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }

            HStack(spacing: 8) {
                Text(footerText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if draft.count >= 200 {
                    Text("\(draft.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.clutchBackground)
        // Paste and drop take the same providers; no keyboard shortcut on
        // the paste button, which would steal the field's text pastes.
        .onPasteCommand(of: [.image, .fileURL], perform: onProviders)
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            onProviders(providers)
            return !providers.isEmpty
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, 8)
            }
        }
    }

    /// Tooltip for the Steer item. When steering is off it says why, so a
    /// greyed-out item is never a mystery.
    private var steerHelp: String {
        if canSteer { return "Give the active turn a new instruction without stopping it." }
        return "Steering is unavailable for this session: the Muse backend did not advertise steering (a native-only launch or an older host). Queue the message instead."
    }

    private var footerText: String {
        if sending {
            return Copy.gap(
                "Working…",
                "Queue sends after this turn; Steer gives the active turn a new instruction."
            )
        }
        return "Return sends · Shift+Return adds a line · ⌘Return also sends"
    }

    private func sendUsingDefaultAction() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if sending {
            switch busySendMode {
            case .queue: onQueue()
            case .steer: onSteer()
            }
        } else {
            onSend()
        }
    }
}
