// qr-png.swift — render stdin as a QR code PNG at argv[1].
// Used by src/web/pair-ios.ts.  Input arrives on stdin so a pairing token
// never appears in the process table.
import AppKit
import CoreImage
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift qr-png.swift <out.png> < text\n".data(using: .utf8)!)
    exit(64)
}
let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard !text.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { exit(65) }
filter.setValue(Data(text.utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
guard let code = filter.outputImage else { exit(70) }

// Scale up crisply and add a white quiet zone.
let scaled = code.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
let margin: CGFloat = 48
let size = CGSize(width: scaled.extent.width + margin * 2, height: scaled.extent.height + margin * 2)
let background = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
let composed = scaled.transformed(by: CGAffineTransform(translationX: margin, y: margin)).composited(over: background)
let context = CIContext()
guard let cg = context.createCGImage(composed, from: composed.extent) else { exit(70) }
let rep = NSBitmapImageRep(cgImage: cg)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(70) }
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CommandLine.arguments[1])
} catch {
    FileHandle.standardError.write("qr-png: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(74)
}
