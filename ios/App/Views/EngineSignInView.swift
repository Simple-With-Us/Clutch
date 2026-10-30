import SwiftUI

/// An explicit browser action gives consent before ACP accepts the login URL.
struct EngineSignInView: View {
    let host: ClutchHost
    var onComplete: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var attempt: EngineAuthenticationAttempt?
    @State private var failure: String?
    @State private var didOpenBrowser = false
    @State private var openingBrowser = false
    @State private var generation = 0
    @State private var activeAttemptId: String?

    private var client: EngineAuthenticationClient { EngineAuthenticationClient(host: host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Sign In To Muse", systemImage: "person.crop.circle.badge.checkmark")
                .font(.title2.bold())
            Text("Account On \(host.name)").font(.subheadline).foregroundStyle(.secondary)

            if attempt?.state == "complete" {
                Label("Muse Is Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("You can now open a thread or submit your message again.")
            } else if let failure {
                Text(failure).foregroundStyle(.red).textSelection(.enabled)
                Button("Try Again") { generation += 1 }
            } else if let attempt, let url = attempt.verificationURL {
                Text(attempt.message ?? "Open the Muse login page and approve the code.")
                    .textSelection(.enabled)
                Text(url.host ?? "").font(.callout.monospaced()).foregroundStyle(.secondary)
                if didOpenBrowser {
                    ProgressView("Waiting For Browser Approval…")
                    Button("Open Login Page Again") { openURL(url) }
                } else {
                    Button("Open Login Page") {
                        openingBrowser = true
                        Task {
                            do {
                                try await client.answer(attempt.attemptId, action: "accept")
                                didOpenBrowser = true
                                openURL(url)
                            } catch {
                                failure = error.localizedDescription
                            }
                            openingBrowser = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(openingBrowser)
                }
            } else {
                ProgressView("Preparing Muse Login…")
            }

            HStack {
                Spacer()
                Button(attempt?.state == "complete" ? "Done" : "Cancel") {
                    if attempt?.state == "complete" { onComplete() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 460, maxWidth: 520)
        .task(id: generation) { await signIn() }
    }

    @MainActor
    private func signIn() async {
        if let previous = activeAttemptId {
            await client.cancel(previous)
            activeAttemptId = nil
        }
        guard !Task.isCancelled else { return }
        failure = nil
        attempt = nil
        didOpenBrowser = false
        var id: String?
        var completed = false
        defer {
            if !completed, let id {
                Task { await client.cancel(id) }
            }
        }
        do {
            let started = try await client.start()
            id = started.attemptId
            activeAttemptId = started.attemptId
            try Task.checkCancellation()
            attempt = started
            for _ in 0..<600 {
                guard let current = attempt else { return }
                if current.state == "complete" { completed = true; return }
                if current.state == "failed" {
                    failure = current.error ?? "Muse could not finish signing in."
                    return
                }
                try await Task.sleep(for: .seconds(1))
                let latest = try await client.status(current.attemptId)
                try Task.checkCancellation()
                attempt = latest
                if latest.state == "waiting", latest.verificationURL == nil {
                    failure = "Muse returned an unsupported login address."
                    return
                }
            }
            failure = "The login expired.\u{00A0} Try again for a new code."
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
