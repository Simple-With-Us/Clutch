import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// Compares a captured surface against a checked-in baseline image.
///
/// The baseline lives in the test bundle as `Baselines/<name>.png`.  A
/// difference beyond the tolerance fails the test and attaches a diff image,
/// so a visual regression ends a build instead of waiting for a human to
/// open the artifact.
///
/// The comparison is scale-invariant on purpose.  A baseline recorded on one
/// machine and compared on another is otherwise useless: the runner has a
/// different screen, a different device and a different CoreText build, so
/// raw pixels differ everywhere and the test fails on every run without
/// saying anything about the app.  Both images are therefore reduced to the
/// same small grid before they are compared, which keeps a moved panel, a
/// recoloured status, a missing row and a changed caption, and drops the
/// antialiasing noise underneath them.
///
/// Record a baseline by running the suite with `CLUTCH_RECORD_SNAPSHOTS=1`
/// and `CLUTCH_SNAPSHOT_DIR` pointing at the baselines folder.  The recorded
/// PNG is the full-resolution capture, so a human can look at it; the
/// comparison is what shrinks it.
extension XCTestCase {
    /// The share of grid cells that may differ before the test fails.
    static let snapshotTolerance: Double = 0.03

    /// The grid both images are reduced to before they are compared.
    static let snapshotGridWidth = 320
    static let snapshotGridHeight = 240

    /// The file that asks a run to record baselines instead of comparing them.
    static let recordFlagName = ".clutch-record-snapshots"

    /// True when the run records baselines instead of comparing them.
    ///
    /// The flag travels in a file at the root of the checkout rather than in
    /// an environment variable, because the test runner does not inherit the
    /// environment of the shell that started the run:  a variable exported
    /// before `xcodebuild` never reaches the bundle that makes the
    /// comparison, so a recording run would compare against a baseline that
    /// was never written.  The path of this file is the path of the source
    /// it was compiled from, so the checkout is always in reach.
    static var recordingSnapshots: Bool {
        if ProcessInfo.processInfo.environment["CLUTCH_RECORD_SNAPSHOTS"] == "1" {
            return true
        }
        for candidate in recordFlagCandidates() {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return true
            }
        }
        return false
    }

    /// Every place the flag may be, and every place it was looked for.
    ///
    /// The runner is sandboxed and the checkout may sit on a volume the
    /// runner cannot read, so the flag is looked for in more than one place
    /// and the scratch directory is always one of them.
    static func recordFlagCandidates() -> [URL] {
        var candidates: [URL] = [
            checkoutRoot().appendingPathComponent(recordFlagName),
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(recordFlagName),
            URL(fileURLWithPath: "/tmp").appendingPathComponent(recordFlagName),
        ]
        if let override = ProcessInfo.processInfo.environment["CLUTCH_RECORD_FLAG_PATH"],
           !override.isEmpty {
            candidates.insert(URL(fileURLWithPath: override), at: 0)
        }
        return candidates
    }

    /// The root of the checkout the tests were compiled from.
    ///
    /// This file lives at `<checkout>/ios/UITests/Support`, so the root is
    /// four directories up.
    static func checkoutRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Asserts that `element` matches the baseline named `name`.
    ///
    /// The element is captured rather than the screen, so a baseline does not
    /// depend on the size of the machine that produced it.
    ///
    /// The call throws when there is no baseline to compare against yet, so
    /// the test is reported as skipped rather than as passed:  a state that
    /// was never compared is not a state that passed, and a green build
    /// that proves nothing is the failure this step exists to prevent.
    func assertSnapshot(
        _ name: String,
        of element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard element.exists else {
            XCTFail(
                "\(name) could not be captured: the element does not exist",
                file: file,
                line: line
            )
            return
        }

        let current = element.screenshot().pngRepresentation

        guard let baselineData = Self.baselineData(for: name, in: self) else {
            if Self.recordingSnapshots {
                Self.recordBaseline(current, named: name)
                // The test runner is sandboxed, so it cannot write the
                // baseline into the repository.  It attaches it instead, and
                // the recording step lifts it out of the result bundle.
                let attachment = XCTAttachment(data: current)
                attachment.name = "\(name)-baseline"
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }
            // There is no baseline to compare against yet.  That is not a
            // pass:  the state was not compared, and a test that reports a
            // pass for a state it never looked at is the green build that
            // proves nothing.  So the test skips, loudly, and the result
            // bundle says which state was not compared.
            //
            // A machine with a simulator runtime records the baseline, and
            // the recording is lifted out of the result bundle by
            // scripts/record-snapshot-baselines.sh.
            print(
                "SNAPSHOT-GAP: no baseline named \(name).png; this state was not compared"
            )
            let env = ProcessInfo.processInfo.environment["CLUTCH_RECORD_SNAPSHOTS"] ?? "<unset>"
            let flags = Self.recordFlagCandidates()
                .map { "\($0.path)=\(FileManager.default.fileExists(atPath: $0.path))" }
                .joined(separator: " | ")
            print("SNAPSHOT-STATE: env=\(env) flags=\(flags) tmp=\(NSTemporaryDirectory())")
            throw XCTSkip(
                "no baseline named \(name).png; this state was not compared",
                file: file,
                line: line
            )
        }

        guard let baseline = Self.decode(baselineData), let shot = Self.decode(current) else {
            XCTFail("\(name) could not be decoded as an image", file: file, line: line)
            return
        }

        let width = Self.snapshotGridWidth
        let height = Self.snapshotGridHeight
        guard let reference = Self.grid(baseline, width: width, height: height),
              let actual = Self.grid(shot, width: width, height: height) else {
            XCTFail("\(name) could not be reduced to the comparison grid", file: file, line: line)
            return
        }

        let differing = Self.differingCellCount(reference, actual)
        let total = width * height
        let ratio = total == 0 ? 0 : Double(differing) / Double(total)

        guard ratio > Self.snapshotTolerance else { return }

        if let diffURL = Self.writeDiffImage(reference, actual, width: width, height: height, named: name) {
            let attachment = XCTAttachment(contentsOfFile: diffURL)
            attachment.name = "\(name)-diff"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTFail(
            String(format: "%@ differs from its baseline by %.2f%% of the surface", name, ratio * 100),
            file: file,
            line: line
        )
    }

    // MARK: - Baselines

    private static func baselineData(for name: String, in test: XCTestCase) -> Data? {
        let bundle = Bundle(for: type(of: test))
        guard let url = bundle.url(forResource: "Baselines/\(name)", withExtension: "png") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private static func recordBaseline(_ data: Data, named name: String) {
        let directory: URL
        // An empty override is not an override:  the script exports the
        // variable whether or not a directory was asked for, and an empty
        // path would write the baseline into whatever the runner's working
        // directory happens to be.
        if let override = ProcessInfo.processInfo.environment["CLUTCH_SNAPSHOT_DIR"],
           !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let fallback = Bundle(for: XCUIScreen.self)
                .bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Baselines", isDirectory: true)
            directory = fallback
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - Pixels

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Reduces an image to a fixed grid of RGBA cells.
    ///
    /// The draw fills the whole grid, so the result does not depend on the
    /// source resolution, only on what the surface looks like.
    private static func grid(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? buffer : nil
    }

    /// A small per-channel tolerance absorbs the antialiasing a focus ring or
    /// a text cursor produces between two runs.
    private static var channelTolerance: Int { 18 }

    private static func differingCellCount(_ reference: [UInt8], _ actual: [UInt8]) -> Int {
        guard reference.count == actual.count else { return 0 }
        var differing = 0
        for index in stride(from: 0, to: reference.count, by: 4) {
            let dr = abs(Int(reference[index]) - Int(actual[index]))
            let dg = abs(Int(reference[index + 1]) - Int(actual[index + 1]))
            let db = abs(Int(reference[index + 2]) - Int(actual[index + 2]))
            if dr > channelTolerance || dg > channelTolerance || db > channelTolerance {
                differing += 1
            }
        }
        return differing
    }

    /// Writes a diff image where unchanged cells go black and changed cells
    /// go magenta, and returns its URL.
    private static func writeDiffImage(
        _ reference: [UInt8],
        _ actual: [UInt8],
        width: Int,
        height: Int,
        named name: String
    ) -> URL? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let limit = min(reference.count, actual.count)
        for index in stride(from: 0, to: limit, by: 4) {
            let changed = abs(Int(reference[index]) - Int(actual[index])) > channelTolerance
                || abs(Int(reference[index + 1]) - Int(actual[index + 1])) > channelTolerance
                || abs(Int(reference[index + 2]) - Int(actual[index + 2])) > channelTolerance
            buffer[index] = changed ? 255 : 0
            buffer[index + 1] = 0
            buffer[index + 2] = changed ? 255 : 0
            buffer[index + 3] = 255
        }
        guard let image = makeImage(from: buffer, width: width, height: height) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-diff.png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    private static func makeImage(from buffer: [UInt8], width: Int, height: Int) -> CGImage? {
        var copy = buffer
        return copy.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }
}
