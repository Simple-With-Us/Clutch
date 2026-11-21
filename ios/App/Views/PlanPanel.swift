import SwiftUI

/// The engine's execution plan, as the engine last reported it.
///
/// The plan is a state rather than a line of the transcript: the engine
/// sends the whole list every time it changes, so the panel replaces what it
/// shows rather than adding to it.
struct PlanPanel: View {
    let entries: [AcpPlanEntry]
    @State private var expanded = false

    private var done: Int { entries.filter(\.isDone).count }

    private var summary: AcpPlanEntry? {
        entries.first(where: \.isActive) ?? entries.first(where: { !$0.isDone }) ?? entries.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.base) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: ClutchSpacing.snug) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(ClutchFont.sectionLabel)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: "list.bullet.rectangle")
                        .font(ClutchFont.microStrong)
                        .foregroundStyle(.secondary)
                    Text("Plan")
                        .font(ClutchFont.captionStrong)
                    Text("\(done)/\(entries.count)")
                        .font(ClutchFont.micro)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse Plan" : "Expand Plan")
            .accessibilityValue("\(done) of \(entries.count) steps complete")

            if expanded {
                #if os(iOS)
                ScrollView {
                    steps
                }
                .frame(maxHeight: 160)
                #else
                steps
                #endif
            } else if let summary {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: mark(for: summary))
                        .font(ClutchFont.sectionLabel)
                        .foregroundStyle(color(for: summary))
                        .frame(width: 12)
                    Text(done == entries.count ? "All steps complete." : summary.content)
                        .font(ClutchFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(ClutchSpacing.cozy)
        .background(ClutchColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: ClutchRadius.card))
        .clutchAnimation(ClutchMotion.quick, value: expanded)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.base) {
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: mark(for: entry))
                        .font(ClutchFont.sectionLabel)
                        .foregroundStyle(color(for: entry))
                        .frame(width: 12)
                    Text(entry.content)
                        .font(ClutchFont.caption)
                        .foregroundStyle(entry.isDone ? ClutchColor.textSecondary : ClutchColor.textPrimary)
                        .strikethrough(entry.isDone, color: .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The mark that says where the entry stands.
    private func mark(for entry: AcpPlanEntry) -> String {
        if entry.isDone { return ClutchStatus.success.symbol }
        if entry.isActive { return ClutchStatus.running.symbol }
        return "circle"
    }

    private func color(for entry: AcpPlanEntry) -> Color {
        if entry.isDone { return ClutchColor.success }
        if entry.isActive { return ClutchColor.accent }
        return .secondary
    }
}
