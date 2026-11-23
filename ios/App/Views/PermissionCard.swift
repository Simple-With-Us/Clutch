import SwiftUI
#if os(iOS)
import LocalAuthentication
#endif

/// The card that answers a permission request.
///
/// The engine is blocked until the request is answered, so the card says
/// what the tool wants and offers the engine's own options.  The web canvas
/// asks the same question in the same place; this is the native answer.
struct PermissionCard: View {
    let request: AcpPermissionRequest
    /// How many more requests are waiting behind this one, when the surface
    /// queues them.  A queue the owner cannot see is a queue that gets
    /// answered out of order.
    var queuedCount: Int = 0
    /// False while the surface has no session for the answer to travel on;
    /// the buttons are held and the card says why instead of swallowing taps.
    var canAnswer: Bool = true
    /// How many answers the surface could not deliver.
    ///
    /// A failed answer leaves the request on screen, so the card has to let
    /// the owner try again: this count moves whenever an answer fails, and
    /// the card offers the request again when it does.
    var answerFailures: Int = 0
    /// How many answers the surface refused because the request they named
    /// was no longer the one on screen.
    ///
    /// The surface is the only place that knows which request is on screen
    /// now, so it drops an answer for a request that has turned over and
    /// says so here, and the card tells the owner.
    var staleAnswers: Int = 0
    /// Called with the answer the owner gave.  The answer names the request
    /// it belongs to, because the owner confirms on a delay — the phone
    /// asks for a face — and the request on screen can turn over while
    /// they do.  A nil option id cancels the request, which is what a deny
    /// amounts to when the engine offered no reject option of its own.
    /// Declared last so call sites can pass it as a trailing closure.
    let onAnswer: (AcpPermissionAnswer) -> Void
    /// True while the answer is on its way, so a double tap cannot answer
    /// the same request twice.
    @State private var isAnswering = false
    /// Why the last allow did not go out, when it did not.
    ///
    /// The card says it rather than swallowing the tap, because an allow
    /// that failed silently looks like an allow that was given.
    @State private var authenticationMessage: String?
    /// The notice that an answer was dropped because the request it named
    /// was no longer the one on screen.
    ///
    /// It has a row of its own because it is about the request the owner
    /// answered, not about the one on screen.
    @State private var staleNotice: String?
    /// The request the notice was raised on.
    ///
    /// The notice belongs to that request and not to the next one, so it
    /// goes when the next request replaces it and cannot misattribute an
    /// older drop to whatever is on screen now.
    @State private var staleNoticeRequestId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.cozy) {
            HStack(spacing: ClutchSpacing.base) {
                Image(systemName: "lock.shield")
                    .font(ClutchFont.footnote.weight(.semibold))
                    .foregroundStyle(ClutchColor.warning)
                Text("Permission Needed")
                    .font(ClutchFont.footnote.weight(.semibold))
                Spacer(minLength: 0)
                if queuedCount > 0 {
                    Text("\(queuedCount) more waiting")
                        .font(ClutchFont.micro)
                        .foregroundStyle(ClutchColor.textSecondary)
                }
                if isAnswering {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(request.headline)
                .font(ClutchFont.footnote)
                .fixedSize(horizontal: false, vertical: true)
            // The tool that wants the permission, when the engine named one:
            // "run pnpm test" from shell reads differently from an edit.
            if request.toolName.trimmingCharacters(in: .whitespaces).isEmpty == false {
                Label(request.toolName, systemImage: "wrench.and.screwdriver")
                    .font(ClutchFont.monoMicro)
                    .foregroundStyle(ClutchColor.textSecondary)
            }
            // What the tool wants to do, so the owner can read it before
            // answering.  An approval nobody can read is not an approval.
            if let evidence = request.evidence, !evidence.lines.isEmpty {
                VStack(alignment: .leading, spacing: ClutchSpacing.tight) {
                    ForEach(evidence.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.label)
                                .font(ClutchFont.microStrong)
                                .foregroundStyle(ClutchColor.textSecondary)
                            Text(line.text)
                                .font(ClutchFont.monoMicro)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityIdentifier("permission-evidence")
            }
            if offeredOptions.isEmpty {
                // An engine that offered no options can only be cancelled.
                Button {
                    answer(nil)
                } label: {
                    Text("Deny")
                        .font(ClutchFont.bodyStrong)
                        .frame(maxWidth: .infinity, minHeight: ClutchMetric.minTapTarget)
                }
                .buttonStyle(.bordered)
                .tint(ClutchColor.danger)
                .disabled(!canAnswer || isAnswering)
                .accessibilityIdentifier("permission-option-deny")
            } else {
                VStack(spacing: ClutchSpacing.base) {
                    ForEach(offeredOptions) { option in
                        // An option that lets the engine proceed is the one
                        // primary action; a refusing option reads as a plain
                        // button, never as a second equally-weighted call to
                        // action, so the card has one obvious default.
                        if option.allows {
                            optionButton(option)
                                .buttonStyle(.borderedProminent)
                                .tint(ClutchColor.accent)
                                .disabled(!canAnswer || isAnswering)
                        } else {
                            optionButton(option)
                                .buttonStyle(.bordered)
                                .tint(ClutchColor.textSecondary)
                                .disabled(!canAnswer || isAnswering)
                        }
                    }
                }
            }
            if let staleNotice {
                Text(staleNotice)
                    .font(ClutchFont.micro)
                    .foregroundStyle(ClutchColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let authenticationMessage {
                Text(authenticationMessage)
                    .font(ClutchFont.micro)
                    .foregroundStyle(ClutchColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !withheldOptions.isEmpty {
                // An option this surface does not offer is named rather than
                // dropped without a word, so the owner can see that the
                // option exists and where it lives.
                VStack(alignment: .leading, spacing: ClutchSpacing.tight) {
                    Text("Mac Only")
                        .font(ClutchFont.microStrong)
                        .foregroundStyle(ClutchColor.textSecondary)
                    ForEach(withheldOptions) { option in
                        Text(displayName(option))
                            .font(ClutchFont.bodyStrong)
                            .foregroundStyle(ClutchColor.textSecondary)
                    }
                    Text(Copy.gap(
                        "The Mac keeps this option, because the owner is at the keyboard there.",
                        "It is not offered on the phone."
                    ))
                    .font(ClutchFont.micro)
                    .foregroundStyle(ClutchColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("permission-withheld-options")
            }
            if !canAnswer {
                Text("Waiting for the turn to start — the answer needs a live session.")
                    .font(ClutchFont.micro)
                    .foregroundStyle(ClutchColor.textSecondary)
            }
        }
        .padding(ClutchSpacing.gutter)
        .background(ClutchColor.warningWash)
        .clipShape(RoundedRectangle(cornerRadius: ClutchRadius.bubble))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Copy.gap("Permission Needed.", request.headline)))
        // The card is addressable by name, so a surface test can ask for the
        // card itself and not for a word that happens to be on it.
        .accessibilityIdentifier("permission-card")
        // A request the owner answered is gone, and one that could not be
        // answered is asked again: either way the card is live.
        .onChange(of: request.id) { _, newValue in
            isAnswering = false
            authenticationMessage = nil
            // The dropped-answer notice belongs to the request it was
            // raised on.  It stays while that request is on screen, so the
            // owner still learns that their confirmation did not go out,
            // and it goes with the next request, so it cannot outlive the
            // request it is about.
            if staleNoticeRequestId != newValue {
                staleNotice = nil
                staleNoticeRequestId = nil
            }
        }
        .onChange(of: answerFailures) { _, _ in
            isAnswering = false
        }
        .onChange(of: staleAnswers) { _, _ in
            // The surface dropped the answer because the request it named
            // was no longer the one on screen.  The card says so and lets
            // the owner answer what is on screen now.
            isAnswering = false
            staleNotice = AcpPermissionAnswer.staleRequestMessage
            staleNoticeRequestId = request.id
        }
    }

    private func optionButton(_ option: AcpPermissionOption) -> some View {
        Button {
            answer(option.optionId)
        } label: {
            HStack(spacing: ClutchSpacing.snug) {
                Image(systemName: mark(for: option))
                Text(displayName(option))
            }
            .font(ClutchFont.bodyStrong)
            .frame(maxWidth: .infinity, minHeight: ClutchMetric.minTapTarget)
        }
        // The engine's own option id is the button's name, so a test can ask
        // for this one button instead of matching a word against every button
        // in the app.  A word match has to ask the app for every button's
        // label and value, and on a loaded runner with a turn running that
        // evaluation times out and the test fails at the query rather than at
        // the card.  The name on screen is the engine's to choose; this one is
        // the app's.
        .accessibilityIdentifier("permission-option-\(option.optionId)")
    }

    /// The engine's own name for the option, with an explicit Always marker
    /// where the choice outlives this turn.
    private func displayName(_ option: AcpPermissionOption) -> String {
        let name = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.isEmpty ? option.kind : name
        switch option.effect {
        case .allowAlways:
            if !label.lowercased().contains("always") {
                return Copy.gap(label, "(Always)")
            }
            return label
        case .unknown:
            // A kind this build has never seen is named as it arrived, so
            // the card does not pretend to know more about it than it does.
            return Copy.gap(label, "(\(option.kind))")
        case .allowOnce, .reject:
            return label
        }
    }

    /// The mark on the button tells the owner what the option does.
    ///
    /// A kind this build does not know gets a question rather than a tick
    /// or a cross, because the build cannot claim to know what it does.
    private func mark(for option: AcpPermissionOption) -> String {
        switch option.effect {
        case .allowOnce, .allowAlways: return "checkmark.circle"
        case .reject: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// The options this surface offers.
    ///
    /// The phone does not offer an allow that outlives the turn, because an
    /// allow the owner cannot see the scope of is not an approval.
    private var offeredOptions: [AcpPermissionOption] {
        #if os(iOS)
        return request.phoneOptions
        #else
        return request.options
        #endif
    }

    /// The options this surface does not offer.
    ///
    /// The phone leaves the allow that outlives the turn to the Mac, and
    /// says here that it left it, so the owner is never left wondering
    /// where an option the engine offered went.
    private var withheldOptions: [AcpPermissionOption] {
        let offered = Set(offeredOptions.map(\.optionId))
        return request.options.filter { !offered.contains($0.optionId) }
    }

    private func answer(_ optionId: String?) {
        guard !isAnswering else { return }
        // The answer names the request it belongs to.  The owner confirms
        // on a delay, and the request on screen can turn over while they
        // do, so the answer carries the id it was given for and the
        // surface drops it if that request is no longer the one on screen.
        let requestId = request.id
        staleNotice = nil
        staleNoticeRequestId = nil
        #if os(iOS)
        // An allow on the phone is the one decision the owner makes away
        // from the keyboard, so it is the one that needs to know the owner
        // is there.  A deny is never gated:  the owner can always say no.
        // The gate is default-deny:  every option but a known refusal waits
        // for the owner's face, so a kind this build has never seen cannot
        // go through unchecked.
        if let optionId,
           let option = request.options.first(where: { $0.optionId == optionId }),
           option.needsOwnerPresence {
            // The buttons go dead before the prompt opens, so a second tap
            // cannot ask for a second face while the first one is up.
            isAnswering = true
            authenticateThenAnswer(optionId, requestId: requestId)
            return
        }
        #endif
        isAnswering = true
        onAnswer(AcpPermissionAnswer(requestId: requestId, optionId: optionId))
    }

    #if os(iOS)
    /// Asks for the owner's face or finger before an allow goes out.
    ///
    /// A device that cannot check the owner cannot answer for the owner, so
    /// the allow is refused and the request waits rather than going out
    /// unchecked.
    private func authenticateThenAnswer(_ optionId: String, requestId: String) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            isAnswering = false
            authenticationMessage = error?.localizedDescription
                ?? "This device cannot check that it is you, so the allow is held."
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Allow this tool to run"
        ) { success, error in
            Task { @MainActor in
                if success {
                    // The answer carries the request it was given for, so an
                    // allow for a request that has since turned over is
                    // dropped by the surface rather than sent to whatever
                    // took its place.
                    onAnswer(AcpPermissionAnswer(requestId: requestId, optionId: optionId))
                } else {
                    isAnswering = false
                    authenticationMessage = error?.localizedDescription
                        ?? "The allow was not confirmed, so it was not given."
                }
            }
        }
    }
    #endif
}
