import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The tiny image preview in a composer attachment chip.
///
/// An attachment travels as base64 image data, so the chip shows the
/// picture itself instead of a generic icon.  Anything that is not
/// decodable image data falls back to the photo glyph: a chip that
/// cannot preview still names and removes the attachment.
public struct AttachmentThumbnail: View {
    public var attachment: ChatAttachment

    public init(attachment: ChatAttachment) {
        self.attachment = attachment
    }

    public var body: some View {
        Group {
            if let image = Self.image(for: attachment) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(ClutchFont.micro)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: ClutchRadius.chip))
        .accessibilityHidden(true)
    }

    /// The attachment's image, or nil when its data is not an image the
    /// platform can decode.
    public static func image(for attachment: ChatAttachment) -> Image? {
        guard let data = Data(base64Encoded: attachment.data) else { return nil }
        #if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #elseif os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }
}
