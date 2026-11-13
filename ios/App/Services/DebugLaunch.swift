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

    #if DEBUG
    private static func argumentValue(after name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    #endif
}
