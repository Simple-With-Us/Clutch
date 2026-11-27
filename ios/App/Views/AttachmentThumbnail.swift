import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import ImageIO

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

    /// Decoded thumbnails by attachment id, so a re-render never pays
    /// for the base64 and image decode again.  NSCache is thread-safe
    /// and evicts under memory pressure.
    #if os(iOS)
    private static let decodedCache = NSCache<NSString, UIImage>()
    #elseif os(macOS)
    private static let decodedCache = NSCache<NSString, NSImage>()
    #endif

    /// The attachment's image, or nil when its data is not an image the
    /// platform can decode.  Decoded once per attachment and downsampled
    /// to thumbnail size at decode time: a pasted photo can be megabytes,
    /// and the chip shows 28 points of it.
    public static func image(for attachment: ChatAttachment) -> Image? {
        let key = attachment.id as NSString
        #if os(iOS)
        if let cached = decodedCache.object(forKey: key) { return Image(uiImage: cached) }
        guard let decoded = downsampled(data: attachment.data) as? UIImage else { return nil }
        decodedCache.setObject(decoded, forKey: key)
        return Image(uiImage: decoded)
        #elseif os(macOS)
        if let cached = decodedCache.object(forKey: key) { return Image(nsImage: cached) }
        guard let decoded = downsampled(data: attachment.data) as? NSImage else { return nil }
        decodedCache.setObject(decoded, forKey: key)
        return Image(nsImage: decoded)
        #else
        return nil
        #endif
    }

    #if os(iOS) || os(macOS)
    private static func downsampled(data base64: String) -> AnyObject? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: thumbnail)
        #else
        return NSImage(cgImage: thumbnail, size: NSSize(width: 96, height: 96))
        #endif
    }
    #endif
}
