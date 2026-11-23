import Foundation

/// Launch arguments that put the app into a state a UI test can drive.
///
/// DEBUG only: the shipping app never reads them, and the values come from
/// the process arguments, so a user cannot reach them by accident.
enum DebugLaunch {
    /// `-ClutchFindText <text>`: the find bar opens with this text in it,
    /// so a UI test can show a highlighted match without typing (the
    /// simulator's keyboard is not dependable in CI).
    static var findText: String? {
        #if DEBUG
        return argumentValue(after: "-ClutchFindText")
        #else
        return nil
        #endif
    }

    /// `-ClutchShowFind 1`: the find bar starts open.
    static var showsFind: Bool {
        #if DEBUG
        return argumentValue(after: "-ClutchShowFind") == "1"
        #else
        return false
        #endif
    }

    /// `-ClutchWindowSize 1040x760`: the workspace window opens at this size.
    ///
    /// A Mac UI test compares the surface against a checked-in baseline, and
    /// the window size is otherwise restored from whatever the last run on
    /// that machine left behind, so it differs from machine to machine.
    /// Asking for a size is also what tells the app to drop the saved layout
    /// it would otherwise reuse.
    static var windowSize: CGSize? {
        #if DEBUG
        guard let raw = argumentValue(after: "-ClutchWindowSize") else { return nil }
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
        #else
        return nil
        #endif
    }

    /// True when the run asked for a fixed window, which means the saved
    /// layout is not the layout under test.
    static var resetsLayout: Bool {
        #if DEBUG
        return windowSize != nil
        #else
        return false
        #endif
    }

    #if DEBUG
    private static func argumentValue(after name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    #endif
}
