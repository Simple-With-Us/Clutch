import SwiftUI

/// The per-session context panel: how full the window is, as a percent,
/// a stacked bar, and the parts it splits into.  It shows only what the
/// engine reported; a thread whose engine named no window shows nothing.
public struct ContextPanel: View {
    public var breakdown: ContextBreakdown

    public init(breakdown: ContextBreakdown) {
        self.breakdown = breakdown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ClutchSpacing.snug) {
            HStack(spacing: 5) {
                Text("Context")
                    .font(ClutchFont.captionStrong)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(String(format: "%.0f%% · %@ / %@", breakdown.usedPercent, AcpSessionUsage.compact(breakdown.usedTokens), AcpSessionUsage.compact(breakdown.window)))
                    .font(ClutchFont.monoMicro)
                    .foregroundStyle(.secondary)
            }
            ContextStackedBar(breakdown: breakdown)
            ForEach(breakdown.segments) { segment in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Self.color(for: segment.kind))
                        .frame(width: 7, height: 7)
                    Text(segment.kind.label)
                        .font(ClutchFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(AcpSessionUsage.compact(segment.tokens))
                        .font(ClutchFont.monoMicro)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func color(for kind: ContextSegmentKind) -> Color {
        switch kind {
        case .input: return ClutchColor.accent
        case .cached: return ClutchColor.info
        case .output: return ClutchColor.success
        case .free: return ClutchColor.surface
        }
    }
}

/// The stacked bar itself: one slice per segment, sized by its share of
/// the window, over the sunken surface the free room reads as.
public struct ContextStackedBar: View {
    public var breakdown: ContextBreakdown

    public init(breakdown: ContextBreakdown) {
        self.breakdown = breakdown
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(breakdown.segments.filter { $0.kind != .free }) { segment in
                    Rectangle()
                        .fill(ContextPanel.color(for: segment.kind))
                        .frame(width: max(0, geometry.size.width * breakdown.fraction(of: segment.kind)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(ClutchColor.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: ClutchRadius.chip))
        .accessibilityLabel("Context \(Int(breakdown.usedPercent.rounded())) percent used")
    }
}
