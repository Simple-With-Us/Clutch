import SwiftUI

/// The panel on the right of the Mac workspace.
///
/// It holds what belongs to the thread rather than to its transcript:  the
/// plan the engine reported, what the context holds, what the thread has
/// used, and the approval the engine is waiting on.  The approval is here
/// as well as on the card, because a reader who has folded the card away
/// still has to be able to answer it.
struct MacInspector: View {
    /// The plan the engine last reported.
    var plan: [AcpPlanEntry]
    /// The newest usage record the sidecar sent.
    var usage: AcpSessionUsage?
    /// What the context holds, when the engine reported it.
    var contextLabel: String?
    /// The approval the engine is waiting on.
    var pendingApproval: AcpPermissionRequest?
    /// Answers the approval.  The answer names the request it belongs to,
    /// so an answer for a request that has turned over is dropped rather
    /// than sent to whatever replaced it.
    var onAnswer: (AcpPermissionAnswer) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ClutchSpacing.cozy) {
                if let pendingApproval {
                    section("Needs You") {
                        approval(pendingApproval)
                    }
                }
                section("Plan") {
                    if plan.isEmpty {
                        empty("The engine has not reported a plan.")
                    } else {
                        ForEach(plan) { entry in
                            planRow(entry)
                        }
                    }
                }
                section("Context") {
                    if let contextLabel {
                        Text(contextLabel)
                            .font(ClutchFont.monoMicro)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        empty("The engine has not reported the context.")
                    }
                }
                section("Usage") {
                    usageRows
                }
            }
            .padding(ClutchSpacing.base)
        }
        .frame(minWidth: 220)
    }

    /// One labelled part of the inspector.
    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.tight) {
            Text(title)
                .font(ClutchFont.sectionLabel)
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// What a part says when there is nothing to show.
    private func empty(_ text: String) -> some View {
        Text(text)
            .font(ClutchFont.caption)
            .foregroundStyle(.secondary)
    }

    /// The approval the engine is waiting on, with the answers it offers.
    private func approval(_ request: AcpPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.tight) {
            Text(request.headline)
                .font(ClutchFont.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            // What the tool wants to do, so the owner can read it before
            // answering.
            if let evidence = request.evidence, !evidence.lines.isEmpty {
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
            ForEach(request.options) { option in
                Button(option.name) {
                    onAnswer(AcpPermissionAnswer(requestId: request.requestId, optionId: option.optionId))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("\(option.name), \(request.title)")
            }
        }
    }

    /// One step of the plan.
    private func planRow(_ entry: AcpPlanEntry) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: planSymbol(entry.status))
                .font(ClutchFont.microStrong)
                .foregroundStyle(planColor(entry.status))
            Text(entry.content)
                .font(ClutchFont.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the engine's own accounting says.
    @ViewBuilder
    private var usageRows: some View {
        if let usage {
            VStack(alignment: .leading, spacing: ClutchSpacing.hair) {
                if let breakdown = usage.contextBreakdown {
                    ContextPanel(breakdown: breakdown)
                }
                if let model = usage.model {
                    usageRow("Model", model)
                }
                usageRow("Input", AcpSessionUsage.compact(usage.inputTokens))
                usageRow("Output", AcpSessionUsage.compact(usage.outputTokens))
                usageRow("Total", AcpSessionUsage.compact(usage.totalTokens))
                if let rate = usage.outputTokensPerSecond {
                    usageRow("Rate", String(format: "%.1f tok/s", rate))
                }
            }
        } else {
            empty("The engine has not reported usage.")
        }
    }

    private func usageRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(ClutchFont.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(ClutchFont.monoMicro)
                .foregroundStyle(.secondary)
        }
    }

    private func planSymbol(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }

    private func planColor(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .accentColor
        default: return .secondary
        }
    }
}
