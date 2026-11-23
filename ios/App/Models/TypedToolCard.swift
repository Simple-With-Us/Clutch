import Foundation

/// What a tool call was and what it answered, read into the shape a card
/// draws.
///
/// The engines write a call as raw JSON and answer it as free text.  A card
/// that shows the name of the tool and nothing else is a card that shows
/// nothing, so the parts a reader wants -  the file that was touched, the
/// lines that changed, the exit code, the tests that failed  -  are read
/// out of what the engine actually wrote.  Nothing here is invented:  a
/// call whose answer does not name an exit code has no exit code, and the
/// card says the status instead.
public struct TypedToolCard: Equatable, Sendable {

    /// The kind of call a card shows.
    public enum Kind: String, Equatable, Sendable {
        /// A file was read.
        case fileRead
        /// A file was changed.
        case fileEdit
        /// A command was run.
        case shell
        /// A suite was run.
        case test
        /// A call of a kind this client does not draw specially.
        case unknown
    }

    /// What the call was called.
    public var name: String
    /// What the call was.
    public var kind: Kind
    /// The file the call touched, when the engine named one.
    public var path: String?
    /// The command the call ran, when the engine named one.
    public var command: String?
    /// The lines the call added.
    public var addedLines: Int
    /// The lines the call removed.
    public var removedLines: Int
    /// The exit code the call ended with, when the answer names one.
    public var exitCode: Int?
    /// What the call answered.
    public var output: String?
    /// How many tests passed, when the answer says.
    public var passed: Int?
    /// How many tests failed, when the answer says.
    public var failed: Int?
    /// The names of the tests that failed, when the answer names them.
    public var failingNames: [String]
    /// The input the engine wrote, for the reader who wants the raw call.
    public var rawInput: String?
    /// The answer the engine wrote, for the reader who wants the raw answer.
    public var rawOutput: String?

    public init(
        name: String,
        kind: Kind = .unknown,
        path: String? = nil,
        command: String? = nil,
        addedLines: Int = 0,
        removedLines: Int = 0,
        exitCode: Int? = nil,
        output: String? = nil,
        passed: Int? = nil,
        failed: Int? = nil,
        failingNames: [String] = [],
        rawInput: String? = nil,
        rawOutput: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.path = path
        self.command = command
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.exitCode = exitCode
        self.output = output
        self.passed = passed
        self.failed = failed
        self.failingNames = failingNames
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }

    /// Reads a call and its answer into a card.
    ///
    /// The name says which tool ran and the arguments say what it was
    /// asked;  the answer says what came back.  Whatever is not in there is
    /// not shown.
    public static func make(
        name: String,
        status: String? = nil,
        input: String? = nil,
        output: String? = nil
    ) -> TypedToolCard {
        let fields = input.flatMap { JSONFields.parse($0) } ?? JSONFields(fields: [:])
        let kind = classify(name: name, fields: fields)
        var card = TypedToolCard(
            name: name,
            kind: kind,
            rawInput: input,
            rawOutput: output
        )
        card.path = fields.string(["path", "file_path", "filePath", "filename", "file", "target_file"])
        card.command = fields.string(["command", "cmd", "script"])
        card.output = output

        if let diff = fields.string(["diff", "patch"]) {
            card.addedLines = LineChange.addedLines(inUnifiedDiff: diff)
            card.removedLines = LineChange.removedLines(inUnifiedDiff: diff)
        } else {
            let old = fields.string(["old_string", "oldString", "before", "old_text"])
            let new = fields.string(["new_string", "newString", "after", "new_text", "content"])
            if old != nil || new != nil {
                let change = LineChange.lineChange(old: old ?? "", new: new ?? "")
                card.addedLines = change.added
                card.removedLines = change.removed
            }
        }

        if let answer = output {
            card.exitCode = ShellResult.exitCode(in: answer)
            let results = TestResult.results(in: answer)
            card.passed = results.passed
            card.failed = results.failed
            card.failingNames = results.failingNames
        }
        return card
    }

    /// The kind of call a name and its arguments name.
    ///
    /// The name is read first because the engines name their tools after
    /// what they do, and the arguments are read next because a tool called
    /// `run` can be a command or a test.
    public static func classify(name: String, fields: JSONFields = JSONFields(fields: [:])) -> Kind {
        let n = name.lowercased()
        if n.contains("test") || fields.string(["test_name", "testName", "test_path"]) != nil {
            return .test
        }
        if n.contains("read") && !n.contains("edit") && !n.contains("write") {
            return .fileRead
        }
        if n.contains("edit") || n.contains("write") || n.contains("patch") || n.contains("apply") {
            return .fileEdit
        }
        if n.contains("bash") || n.contains("shell") || n.contains("exec")
            || n.contains("command") || n.contains("terminal") || n.hasPrefix("run") {
            return .shell
        }
        if n.hasPrefix("read") { return .fileRead }
        if fields.string(["command", "cmd"]) != nil { return .shell }
        if fields.string(["old_string", "oldString", "new_string", "newString"]) != nil { return .fileEdit }
        return .unknown
    }

    /// The headline the card shows.
    ///
    /// It names what happened, in the order a reader wants it:  the file,
    /// then what changed;  the command, then how it ended;  the suite, then
    /// how many passed and which failed.
    public var headline: String {
        switch kind {
        case .fileRead:
            return path.map { "Read \($0)" } ?? "Read a file"
        case .fileEdit:
            guard let path else { return "Changed a file" }
            if addedLines == 0 && removedLines == 0 { return "Changed \(path)" }
            return "Changed \(path)  +\(addedLines)  −\(removedLines)"
        case .shell:
            return command ?? "Ran a command"
        case .test:
            return "Ran the tests"
        case .unknown:
            return name
        }
    }

    /// The one line under the headline, when there is one to show.
    public var detail: String? {
        switch kind {
        case .fileEdit:
            guard addedLines > 0 || removedLines > 0 else { return nil }
            return "+\(addedLines)  −\(removedLines)"
        case .shell:
            guard let exitCode else { return nil }
            return exitCode == 0 ? "Exit 0" : "Exit \(exitCode)"
        case .test:
            var parts: [String] = []
            if let passed { parts.append("\(passed) passed") }
            if let failed { parts.append("\(failed) failed") }
            if parts.isEmpty { return nil }
            if !failingNames.isEmpty {
                parts.append(failingNames.prefix(3).joined(separator: ", "))
            }
            return parts.joined(separator: "  ")
        case .fileRead, .unknown:
            return nil
        }
    }
}

// MARK: - Reading what the engine wrote

/// A value the engine wrote, read without guessing.
public enum JSONValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Reads a value the engine wrote into a JSON value.
    public static func from(_ raw: Any) -> JSONValue {
        switch raw {
        case is NSNull: return .null
        case let value as String: return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        case let value as [Any]: return .array(value.map { JSONValue.from($0) })
        case let value as [String: Any]:
            return .object(value.mapValues { JSONValue.from($0) })
        default: return .null
        }
    }

    /// The value as a string, when it is one.
    var text: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }
}

/// The fields of a call's arguments.
public struct JSONFields {
    /// The fields, read from a JSON object.
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    /// The fields of a JSON object, or nothing when the text is not one.
    public static func parse(_ text: String) -> JSONFields? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let dictionary = object as? [String: Any] else { return nil }
        return JSONFields(fields: dictionary.mapValues { JSONValue.from($0) })
    }

    /// The first of the named fields that holds a string.
    public func string(_ names: [String]) -> String? {
        for name in names {
            if let value = fields[name]?.text, !value.isEmpty { return value }
        }
        return nil
    }

}

/// Reads what the engine wrote about a change.
public enum LineChange {
    /// How many lines a change added and removed.
    ///
    /// The lines both sides share cancel out, so what is left over on the
    /// new side was added and what is left over on the old side was
    /// removed.  A line that appears twice is counted twice.
    static func lineChange(old: String, new: String) -> (added: Int, removed: Int) {
        var remaining = lines(of: old)
        var added = 0
        for line in lines(of: new) {
            if let index = remaining.firstIndex(of: line) {
                remaining.remove(at: index)
            } else {
                added += 1
            }
        }
        return (added, remaining.count)
    }

    /// The lines of a text, with no line for an empty text.
    private static func lines(of text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.components(separatedBy: .newlines)
    }

    /// How many lines a unified diff added.
    static func addedLines(inUnifiedDiff diff: String) -> Int {
        diff.components(separatedBy: .newlines).filter { line in
            line.hasPrefix("+") && !line.hasPrefix("+++")
        }.count
    }

    /// How many lines a unified diff removed.
    static func removedLines(inUnifiedDiff diff: String) -> Int {
        diff.components(separatedBy: .newlines).filter { line in
            line.hasPrefix("-") && !line.hasPrefix("---")
        }.count
    }
}

/// Reads what the engine wrote about a command that ran.
public enum ShellResult {
    /// The exit code an answer names.
    ///
    /// The engines write it in more than one way, so the ways they write it
    /// are read.  An answer that names no exit code has none:  the card
    /// says the status the call reported instead.
    static func exitCode(in answer: String) -> Int? {
        let patterns = [
            #"exit(?:ed)?(?:\s+with)?\s+(?:code|status)\s*[:=]?\s*(-?\d+)"#,
            #"process\s+exited\s+with\s+(?:code\s+)?(-?\d+)"#,
            #"command\s+exited\s+with\s+(?:code\s+)?(-?\d+)"#,
            #"\bcode\s*[:=]\s*(-?\d+)\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
            guard let match = regex.firstMatch(in: answer, range: range),
                  let codeRange = Range(match.range(at: 1), in: answer) else { continue }
            if let code = Int(answer[codeRange]) { return code }
        }
        return nil
    }
}

/// Reads what the engine wrote about a suite that ran.
public enum TestResult {
    /// How many tests passed and failed, and which failed.
    static func results(in answer: String) -> (passed: Int?, failed: Int?, failingNames: [String]) {
        let passed = firstCount(in: answer, patterns: [
            #"(\d+)\s+(?:tests?\s+)?passed"#,
            #"passed\s*[:=]\s*(\d+)"#,
            #"ok\s+(\d+)"#,
        ])
        let failed = firstCount(in: answer, patterns: [
            #"(\d+)\s+(?:tests?\s+)?failed"#,
            #"failed\s*[:=]\s*(\d+)"#,
            #"not\s+ok\s+(\d+)"#,
        ])
        let names = failingNames(in: answer)
        return (passed, failed, names)
    }

    /// The first count an answer names.
    private static func firstCount(in answer: String, patterns: [String]) -> Int? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
            guard let match = regex.firstMatch(in: answer, range: range),
                  let countRange = Range(match.range(at: 1), in: answer),
                  let count = Int(answer[countRange]) else { continue }
            return count
        }
        return nil
    }

    /// The names of the tests that failed.
    ///
    /// The suites write the failures in a few ways and all of them are
    /// read.  A suite that names none simply names none.
    private static func failingNames(in answer: String) -> [String] {
        var names: [String] = []
        for line in answer.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var name: String?
            if trimmed.hasPrefix("FAIL ") {
                name = String(trimmed.dropFirst(5))
            } else if trimmed.hasPrefix("✗ ") || trimmed.hasPrefix("✕ ") {
                name = String(trimmed.dropFirst(2))
            } else if trimmed.hasPrefix("not ok ") {
                name = String(trimmed.dropFirst(7))
            }
            guard let value = name?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { continue }
            // A suite writes the test name and then the reason, so only the
            // first piece of the line is the name.
            let short = value.components(separatedBy: " - ").first ?? value
            names.append(short)
        }
        return names
    }
}
