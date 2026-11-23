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
                .accessibilityIdentifier(PermissionCard.denyOptionIdentifier)
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
        // The card is a container and not a label.
        //
        // A container that carries its own label asks the accessibility
        // server to describe the card and its children together, and the
        // children here are the engine's own options:  a button a surface
        // cannot reach is an option the owner cannot pick.  The card's
        // words are its own text, so VoiceOver reads them in order and
        // every option stays an option of its own.
        .accessibilityElement(children: .contain)
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
        .accessibilityIdentifier(PermissionCard.optionIdentifier(for: option))
    }

    /// The identifier an option button carries.
    ///
    /// The engine names its own options, so the identifier is built from
    /// the name the engine used:  a surface test can ask for the exact
    /// option the engine asked for, and two engines that word the same
    /// choice differently still get two different buttons.
    ///
    /// The rule here and the rule the surface tests use are the same one:
    /// the engine's name, lowercased, with everything that is not a letter
    /// or a number turned into a dash.
    static func optionIdentifier(for option: AcpPermissionOption) -> String {
        "permission-option-\(slug(option.optionId))"
    }

    /// The identifier the deny button carries, for an engine that offered
    /// no options of its own.
    static let denyOptionIdentifier = "permission-option-deny"

    /// A name reduced to the letters and numbers an identifier can hold.
    private static func slug(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
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
