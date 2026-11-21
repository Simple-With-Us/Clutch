import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The design-token layer for both native apps.
///
/// Every colour, type role, spacing, radius, and status treatment the apps
/// draw comes from here, so the same concept renders the same way on iOS
/// and macOS and follows the user's text size and appearance.  The layer
/// is behaviour-preserving for surfaces that keep their current values;
/// call sites migrate to it one file at a time.
///
/// Design literals (`cornerRadius: 8`, `.system(size: 10)`) belong nowhere
/// outside this file once a surface has migrated.
///
// MARK: - Dynamic colour

extension Color {
    /// A colour that resolves per appearance, with the platform branch in
    /// exactly one place.  `UIColor(dynamicProvider:)` and
    /// `NSColor(name:dynamicProvider:)` are the two constructors that exist
    /// on both platforms.
    static func clutchDynamic(
        light: (r: Double, g: Double, b: Double),
        dark: (r: Double, g: Double, b: Double)
    ) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #endif
    }
}

/// Colour roles.  Surfaces keep the values the apps already draw, so a
/// migrated call site is behaviour-preserving; the semantic status colours
/// are tuned to clear contrast on `surface` in both appearances, which the
/// bare system greens and oranges the apps used before do not.
public enum ClutchColor {
    /// The window canvas behind everything.
    public static let canvas = Color.clutchBackground
    /// Cards, rails, and strips that sit on the canvas.
    public static let surface = Color.clutchSecondaryBackground
    /// Wells and input fields that sit inside a card.
    public static let surfaceSunken = Color.clutchDynamic(
        light: (r: 0.949, g: 0.949, b: 0.969),
        dark: (r: 0.110, g: 0.110, b: 0.118)
    )

    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary
    /// SwiftUI's `Color` has no `tertiary`; the hierarchy label is a dimmed
    /// primary so it reads correctly in light and dark without reaching for
    /// a platform-only label colour.
    public static let textTertiary = Color.primary.opacity(0.55)

    public static let accent = Color.accentColor
    /// A light wash of the accent behind content that belongs to it.
    public static let accentWash = Color.accentColor.opacity(0.14)

    /// Status colours.  Light values are dark enough, and dark values light
    /// enough, to read at small sizes on `surface`.
    public static let success = Color.clutchDynamic(
        light: (r: 0.000, g: 0.478, b: 0.271),
        dark: (r: 0.290, g: 0.870, b: 0.502)
    )
    public static let warning = Color.clutchDynamic(
        light: (r: 0.620, g: 0.360, b: 0.000),
        dark: (r: 1.000, g: 0.720, b: 0.300)
    )
    public static let danger = Color.clutchDynamic(
        light: (r: 0.729, g: 0.106, b: 0.106),
        dark: (r: 1.000, g: 0.420, b: 0.420)
    )
    public static let info = Color.clutchDynamic(
        light: (r: 0.000, g: 0.400, b: 0.700),
        dark: (r: 0.400, g: 0.700, b: 1.000)
    )

    /// The wash behind a warning surface, as used by the permission card.
    public static let warningWash = warning.opacity(0.12)
    /// The wash behind an error surface.
    public static let dangerWash = danger.opacity(0.12)
}

// MARK: - Type

/// Type roles.  Every token is a semantic text style, so it tracks Dynamic
/// Type; nothing here freezes a point size.  The fixed sizes the apps used
/// before map onto these roles:  13 pt to `footnote`, 12 pt to `caption`,
/// 11 pt and below to `caption2`, body prose to `body`.
public enum ClutchFont {
    public static let display = Font.largeTitle.weight(.bold)
    public static let title = Font.title2.weight(.bold)
    public static let headline = Font.headline
    public static let body = Font.body
    public static let bodyStrong = Font.body.weight(.semibold)
    public static let callout = Font.callout
    public static let footnote = Font.footnote
    public static let caption = Font.caption
    public static let captionStrong = Font.caption.weight(.semibold)

    /// The dense chrome scale for labels, badges, and section markers.
    public static let micro = Font.caption2
    public static let microStrong = Font.caption2.weight(.semibold)
    public static let sectionLabel = Font.caption2.weight(.bold)

    /// Monospaced roles for tool input, paths, and code.
    public static let mono = Font.footnote.monospaced()
    public static let monoMicro = Font.caption2.monospaced()
    public static let monoBody = Font.body.monospaced()
}

// MARK: - Spacing

/// Spacing on a 4 pt-derived scale.  `gutter` is the horizontal inset every
/// strip and card uses; `snug` and `base` are the stack gaps.
public enum ClutchSpacing {
    public static let hair: CGFloat = 2
    public static let tight: CGFloat = 4
    public static let snug: CGFloat = 6
    public static let base: CGFloat = 8
    public static let cozy: CGFloat = 10
    public static let gutter: CGFloat = 12
    public static let section: CGFloat = 16
    public static let screen: CGFloat = 24
}

// MARK: - Radius

/// Corner radius roles.  A chip, a control, a card, a transcript bubble,
/// the composer, and a sheet each have exactly one radius.
public enum ClutchRadius {
    public static let chip: CGFloat = 6
    public static let control: CGFloat = 8
    public static let card: CGFloat = 10
    public static let bubble: CGFloat = 12
    public static let composer: CGFloat = 14
    public static let sheet: CGFloat = 16
}

// MARK: - Metrics

/// Shared layout metrics.
public enum ClutchMetric {
    /// The smallest tappable control edge, per the accessibility baseline.
    public static let minTapTarget: CGFloat = 44
    /// The widest line of transcript prose before it wraps.
    public static let readableWidth: CGFloat = 720
    /// The thread rail's default and drag bounds.
    public static let railWidth: CGFloat = 248
    public static let railMin: CGFloat = 180
    public static let railMax: CGFloat = 460
}

// MARK: - Motion

/// Motion durations.  `stream` is the near-instant tick a streaming
/// transcript uses; the others are collapse and reveal transitions.
public enum ClutchMotion {
    public static let quick = Animation.easeInOut(duration: 0.15)
    public static let standard = Animation.easeInOut(duration: 0.2)
    public static let stream = Animation.linear(duration: 0.12)
}

/// Animates `value` unless the user asked for reduced motion, which the
/// apps must honour everywhere they animate.
private struct ClutchAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Applies `animation` to changes of `value` unless Reduce Motion is on.
    public func clutchAnimation<V: Equatable>(
        _ animation: Animation,
        value: V
    ) -> some View {
        modifier(ClutchAnimationModifier(animation: animation, value: value))
    }
}

/// The one card treatment: padded surface, `card` radius, continuous
/// corners.  Replaces the hand-rolled variants per surface.
public struct ClutchCardStyle: ViewModifier {
    let padding: CGFloat

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                ClutchColor.surface,
                in: RoundedRectangle(cornerRadius: ClutchRadius.card, style: .continuous)
            )
    }
}

extension View {
    public func clutchCard(padding: CGFloat = ClutchSpacing.gutter) -> some View {
        modifier(ClutchCardStyle(padding: padding))
    }

    /// Grows an icon-only control to the minimum tap target so the whole
    /// padded box is hit-testable.
    public func clutchTapTarget() -> some View {
        frame(
            minWidth: ClutchMetric.minTapTarget,
            minHeight: ClutchMetric.minTapTarget
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Status

/// Where something stands, carrying its colour, symbol, and spoken label
/// together, so status is never colour alone and never re-derived per
/// surface with a different answer.
public enum ClutchStatus {
    case success
    case warning
    case danger
    case running
    case idle

    public var color: Color {
        switch self {
        case .success: return ClutchColor.success
        case .warning: return ClutchColor.warning
        case .danger: return ClutchColor.danger
        case .running: return ClutchColor.info
        case .idle: return ClutchColor.textTertiary
        }
    }

    public var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .idle: return "circle.dashed"
        }
    }

    public var label: String {
        switch self {
        case .success: return "Complete"
        case .warning: return "Needs Attention"
        case .danger: return "Failed"
        case .running: return "Running"
        case .idle: return "Unknown"
        }
    }

    /// Maps a tool call's status word to a status.  A completed call is a
    /// success, a failed call is a danger, and everything else is running.
    public init(toolStatus: String) {
        switch toolStatus {
        case "completed": self = .success
        case "failed": self = .danger
        default: self = .running
        }
    }
}
