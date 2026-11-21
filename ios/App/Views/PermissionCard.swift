import SwiftUI

/// The card that answers a permission request.
///
/// The engine is blocked until the request is answered, so the card says
/// what the tool wants and offers the engine's own options.  The web canvas
/// asks the same question in the same place; this is the native answer.
struct PermissionCard: View {
    let request: AcpPermissionRequest
    /// Called with the option the owner picked.  A nil id cancels the
    /// request, which is what a deny amounts to when the engine offered no
    /// reject option of its own.
    let onAnswer: (String?) -> Void
    /// True while the answer is on its way, so a double tap cannot answer
    /// the same request twice.
    @State private var isAnswering = false

    var body: some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.cozy) {
            HStack(spacing: ClutchSpacing.base) {
                Image(systemName: "lock.shield")
                    .font(ClutchFont.footnote.weight(.semibold))
                    .foregroundStyle(ClutchColor.warning)
                Text("Permission Needed")
                    .font(ClutchFont.footnote.weight(.semibold))
                Spacer(minLength: 0)
                if isAnswering {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(request.headline)
                .font(ClutchFont.footnote)
                .fixedSize(horizontal: false, vertical: true)
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
                .disabled(isAnswering)
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
                                .disabled(isAnswering)
                        } else {
                            optionButton(option)
                                .buttonStyle(.bordered)
                                .tint(ClutchColor.textSecondary)
                                .disabled(isAnswering)
                        }
                    }
                }
            }
        }
        .padding(ClutchSpacing.gutter)
        .background(ClutchColor.warningWash)
        .clipShape(RoundedRectangle(cornerRadius: ClutchRadius.bubble))
        .accessibilityElement(children: .contain)
    }

    private func optionButton(_ option: AcpPermissionOption) -> some View {
        Button {
            answer(option.optionId)
        } label: {
            Text(option.name.isEmpty ? option.kind : option.name)
                .font(ClutchFont.bodyStrong)
                .frame(maxWidth: .infinity, minHeight: ClutchMetric.minTapTarget)
        }
    }

    private func answer(_ optionId: String?) {
        guard !isAnswering else { return }
        isAnswering = true
        onAnswer(optionId)
    }
}
