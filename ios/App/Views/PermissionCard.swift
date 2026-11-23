import SwiftUI

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
    /// Called with the option the owner picked.  A nil id cancels the
    /// request, which is what a deny amounts to when the engine offered no
    /// reject option of its own.  Declared last so call sites can pass it
    /// as a trailing closure.
    let onAnswer: (String?) -> Void
    /// True while the answer is on its way, so a double tap cannot answer
    /// the same request twice.
    @State private var isAnswering = false
    /// How many answers the surface could not deliver.
    ///
    /// A failed answer leaves the request on screen, so the card has to let
    /// the owner try again: this count moves whenever an answer fails, and
    /// the card offers the request again when it does.
    var answerFailures: Int = 0

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
            if request.options.isEmpty {
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
                    ForEach(request.options) { option in
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
        .onChange(of: request.id) { _, _ in
            isAnswering = false
        }
        .onChange(of: answerFailures) { _, _ in
            isAnswering = false
        }
    }

    private func optionButton(_ option: AcpPermissionOption) -> some View {
        Button {
            answer(option.optionId)
        } label: {
            HStack(spacing: ClutchSpacing.snug) {
                Image(systemName: option.allows ? "checkmark.circle" : "xmark.circle")
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
        if name.isEmpty { return option.kind }
        if option.kind == "allow_always", !name.lowercased().contains("always") {
            return Copy.gap(name, "(Always)")
        }
        return name
    }

    private func answer(_ optionId: String?) {
        guard !isAnswering else { return }
        isAnswering = true
        onAnswer(optionId)
    }
}
