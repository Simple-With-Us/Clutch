import Foundation

/// One image attached to a turn.
///
/// The phone has no shared filesystem with the server, so an attachment
/// travels as base64 data in the chat request — the same way the web
/// canvas sends a pasted image.
public struct ChatAttachment: Equatable, Sendable, Identifiable {
    public var id: String
    public var mimeType: String
    public var data: String
    public var name: String

    public init(id: String = UUID().uuidString, mimeType: String, data: String, name: String) {
        self.id = id
        self.mimeType = mimeType
        self.data = data
        self.name = name
    }

    /// The image MIME types the code engines accept.
    public static let supportedTypes = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Build an attachment from image bytes, or nil when the bytes are not
    /// an image type the engines take.
    public static func from(data: Data, name: String) -> ChatAttachment? {
        guard let mimeType = detectMimeType(data) else { return nil }
        return ChatAttachment(mimeType: mimeType, data: data.base64EncodedString(), name: name)
    }

    /// The image type from the bytes themselves, not from the file name: a
    /// renamed file would otherwise be sent with the wrong type and the
    /// engine would refuse it.
    public static func detectMimeType(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 { return "image/png" }
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF { return "image/jpeg" }
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 { return "image/gif" }
        // RIFF....WEBP
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
            && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return "image/webp"
        }
        return nil
    }

    /// A short label for the composer chip.
    public var displayName: String {
        name.isEmpty ? "Image" : name
    }
}
