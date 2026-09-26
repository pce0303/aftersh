import Foundation

/// Sanitized finding derived from temporary content comparison (no raw file bodies).
public struct SemanticSummary: Equatable, Sendable, Codable {
    public var kind: String
    public var message: String
    public var path: String

    public init(kind: String, message: String, path: String) {
        self.kind = kind
        self.message = message
        self.path = path
    }
}

/// Conservative literal shell assignment recognition (does not execute shell).
public enum PathSemanticDiff {
    /// Match `PATH=...` or `export PATH=...` (optional quotes).
    private static let pathLine = try! NSRegularExpression(
        pattern: #"^\s*(?:export\s+)?PATH=(.*)$"#,
        options: [.anchorsMatchLines]
    )

    public static func summarize(
        beforeText: String?,
        afterText: String?,
        displayPath: String
    ) -> [SemanticSummary] {
        guard let beforeText, let afterText, beforeText != afterText else {
            return []
        }

        let beforeEntries = pathEntries(in: beforeText)
        let afterEntries = pathEntries(in: afterText)
        guard !beforeEntries.isEmpty || !afterEntries.isEmpty else {
            return []
        }

        let beforeSet = Set(beforeEntries)
        let afterSet = Set(afterEntries)
        let added = afterEntries.filter { !beforeSet.contains($0) }
        let removed = beforeEntries.filter { !afterSet.contains($0) }

        var summaries: [SemanticSummary] = []
        for entry in added {
            summaries.append(
                SemanticSummary(
                    kind: "path_entry_added",
                    message: "PATH entry added: \(entry)",
                    path: displayPath
                )
            )
        }
        for entry in removed {
            summaries.append(
                SemanticSummary(
                    kind: "path_entry_removed",
                    message: "PATH entry removed: \(entry)",
                    path: displayPath
                )
            )
        }
        return summaries
    }

    /// Last literal PATH assignment in the file wins (common for shell rc snippets).
    public static func pathEntries(in text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = pathLine.matches(in: text, options: [], range: range)
        guard let last = matches.last else { return [] }

        var value = ns.substring(with: last.range(at: 1))
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        return value
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.isEmpty }
    }
}
