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

    /// `-ClutchPairingLink <url>`: the app pairs with this link before it
    /// draws anything.
    ///
    /// A UI test needs the app to be talking to its stub before the first
    /// frame, and a launch argument is the one channel that reaches the app
    /// on every machine:  a file the test writes is not readable from the
    /// app, because the test runner's container is protected, and an
    /// environment variable does not always survive the launch.
    ///
    /// The link is debug-only, so a shipped build never pairs from a
    /// command line.
    static var pairingLink: String? {
        #if DEBUG
        return argumentValue(after: "-ClutchPairingLink")
        #else
        return nil
        #endif
    }

    /// `-ClutchDefaultsSuite <name>`: the app keeps its paired hosts in
    /// this preferences suite instead of its own.
    ///
    /// The host list is what the app stores in preferences, so a UI test
    /// that writes to the app's own suite would unpair the hosts the owner
    /// has on this machine.  A suite of the test's own keeps the run away
    /// from the owner's configuration entirely.
    static var defaultsSuite: String? {
        #if DEBUG
        return argumentValue(after: "-ClutchDefaultsSuite")
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
