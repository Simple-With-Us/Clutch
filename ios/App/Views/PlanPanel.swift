import SwiftUI

/// The engine's execution plan, as the engine last reported it.
///
/// The plan is a state rather than a line of the transcript: the engine
/// sends the whole list every time it changes, so the panel replaces what it
/// shows rather than adding to it.
struct PlanPanel: View {
    let entries: [AcpPlanEntry]

    private var done: Int { entries.filter(\.isDone).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Plan")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(done)/\(entries.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: mark(for: entry))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(color(for: entry))
                        .frame(width: 12)
                    Text(entry.content)
                        .font(.system(size: 12))
                        .foregroundStyle(entry.isDone ? Color.secondary : Color.primary)
                        .strikethrough(entry.isDone, color: .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .background(Color.clutchSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// The mark that says where the entry stands.
    private func mark(for entry: AcpPlanEntry) -> String {
        if entry.isDone { return "checkmark.circle.fill" }
        if entry.isActive { return "arrow.triangle.2.circlepath" }
        return "circle"
    }

    private func color(for entry: AcpPlanEntry) -> Color {
        if entry.isDone { return .green }
        if entry.isActive { return .accentColor }
        return .secondary
    }
}
