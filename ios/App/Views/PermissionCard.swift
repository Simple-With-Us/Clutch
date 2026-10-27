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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Permission Needed")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if isAnswering {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(request.headline)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if request.options.isEmpty {
                // An engine that offered no options can only be cancelled.
                Button("Deny") {
                    answer(nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAnswering)
            } else {
                HStack(spacing: 8) {
                    ForEach(request.options) { option in
                        Button {
                            answer(option.optionId)
                        } label: {
                            Text(option.name.isEmpty ? option.kind : option.name)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(option.allows ? Color.accentColor : Color.secondary)
                        .disabled(isAnswering)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func answer(_ optionId: String?) {
        guard !isAnswering else { return }
        isAnswering = true
        onAnswer(optionId)
    }
}
