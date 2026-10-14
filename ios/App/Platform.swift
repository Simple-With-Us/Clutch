import SwiftUI

#if os(macOS)
import AppKit
/// UIImage alias so shared views can load bundled images on either OS.
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
/// NSImage alias so shared views can load bundled images on either OS.
typealias PlatformImage = UIImage
#endif

/// System-background colors that compile on both iOS and macOS.
/// Call sites use these instead of `Color(.systemBackground)` /
/// `Color(.secondarySystemBackground)`, which are UIKit-only initializers.
extension Color {
    static var clutchBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }

    static var clutchSecondaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }
}
