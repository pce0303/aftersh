import Foundation

public enum ReceiptVerbosity: String, Sendable {
    /// Short post-run output: status, exit, notable changes, save id.
    case summary
    /// Full trust-oriented receipt for `inspect` / `--verbose`.
    case detailed
}

/// Renders a human-readable receipt from observation results.
public enum ReceiptRenderer {
    public struct Input: Sendable {
        public var commandExecutable: String
        public var argumentsOmitted: Bool
        public var termination: ProcessTermination?
        public var commandDuration: TimeInterval?
        public var scopeStatus: ObservationStatus
        public var watchedPaths: [String]
        public var excludedPaths: [PathExclusion]
        public var failures: [ScanFailure]
        public var changes: [ObservedChange]
        public var semanticSummaries: [SemanticSummary]
        public var contentLimitations: [String]
        public var savedReceiptId: String?
        public var saveFailed: Bool
        public var verbosity: ReceiptVerbosity

        public init(
            commandExecutable: String,
            argumentsOmitted: Bool = true,
            termination: ProcessTermination?,
            commandDuration: TimeInterval? = nil,
            scopeStatus: ObservationStatus,
            watchedPaths: [String],
            excludedPaths: [PathExclusion],
            failures: [ScanFailure],
            changes: [ObservedChange],
            semanticSummaries: [SemanticSummary] = [],
            contentLimitations: [String] = [],
            savedReceiptId: String? = nil,
            saveFailed: Bool = false,
            verbosity: ReceiptVerbosity = .detailed
        ) {
            self.commandExecutable = commandExecutable
            self.argumentsOmitted = argumentsOmitted
            self.termination = termination
            self.commandDuration = commandDuration
            self.scopeStatus = scopeStatus
            self.watchedPaths = watchedPaths
            self.excludedPaths = excludedPaths
            self.failures = failures
            self.changes = changes
            self.semanticSummaries = semanticSummaries
            self.contentLimitations = contentLimitations
            self.savedReceiptId = savedReceiptId
            self.saveFailed = saveFailed
            self.verbosity = verbosity
        }

        public init(
            commandExecutable: String,
            termination: ProcessTermination?,
            commandDuration: TimeInterval? = nil,
            scope: ObservationScope,
            changes: [ObservedChange],
            semanticSummaries: [SemanticSummary] = [],
            contentLimitations: [String] = [],
            savedReceiptId: String? = nil,
            saveFailed: Bool = false,
            verbosity: ReceiptVerbosity = .detailed
        ) {
            self.init(
                commandExecutable: commandExecutable,
                argumentsOmitted: true,
                termination: termination,
                commandDuration: commandDuration,
                scopeStatus: scope.status,
                watchedPaths: scope.watchedPaths,
                excludedPaths: scope.excludedPaths,
                failures: scope.failures,
                changes: changes,
                semanticSummaries: semanticSummaries,
                contentLimitations: contentLimitations,
                savedReceiptId: savedReceiptId,
                saveFailed: saveFailed,
                verbosity: verbosity
            )
        }
    }

    /// Directory MODIFY with no permission/symlink change — common noise next to CREATE/DELETE
    /// (mtime and directory size often change when children are added).
    public static func isDirectoryMetadataOnlyModify(_ change: ObservedChange) -> Bool {
        guard change.kind == .modified,
              let before = change.before,
              let after = change.after,
              before.type == .directory,
              after.type == .directory
        else {
            return false
        }
        return before.permissions == after.permissions
            && before.symlinkTarget == after.symlinkTarget
    }

    public static func render(_ input: Input) -> String {
        switch input.verbosity {
        case .summary:
            return renderSummary(input)
        case .detailed:
            return renderDetailed(input)
        }
    }

    public static func render(
        receipt: Receipt,
        verbosity: ReceiptVerbosity = .detailed
    ) -> String {
        render(
            .init(
                commandExecutable: receipt.commandExecutable,
                argumentsOmitted: receipt.argumentsOmitted,
                termination: receipt.termination,
                commandDuration: receipt.commandDuration,
                scopeStatus: receipt.observation.status,
                watchedPaths: receipt.observation.watchedPaths,
                excludedPaths: receipt.observation.excludedPaths,
                failures: receipt.observation.failures,
                changes: receipt.changes,
                semanticSummaries: receipt.semanticSummaries,
                contentLimitations: receipt.contentLimitations,
                savedReceiptId: receipt.id,
                saveFailed: false,
                verbosity: verbosity
            )
        )
    }

    public static func renderHistory(_ receipts: [Receipt]) -> String {
        if receipts.isEmpty {
            return "No saved receipts."
        }

        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for receipt in receipts {
            let ended = formatter.string(from: receipt.endedAt)
            let status = receipt.observation.status.rawValue.uppercased()
            let args = receipt.argumentsOmitted ? "args omitted" : "args recorded"
            lines.append(
                "\(receipt.id)  \(ended)  \(status)  changes=\(receipt.changes.count)  \(receipt.commandExecutable)  (\(args))"
            )
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Summary

    private static func renderSummary(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("AFTERSH")
        lines.append("Observation  \(input.scopeStatus.rawValue.uppercased())")
        lines.append("Command      \(input.commandExecutable)")
        if let termination = input.termination {
            switch termination {
            case .exited(let code):
                lines.append("Exit         \(code)")
            case .signaled(let signal):
                lines.append(
                    "Signal       \(signal) (wrapper exit \(termination.wrapperExitCode))"
                )
            }
        }
        lines.append("")

        let buckets = ImportanceRanker.summarize(
            changes: input.changes,
            semanticSummaries: input.semanticSummaries
        )
        let collapsedDirs = buckets.collapsedDirectoryMetadataCount

        if input.scopeStatus == .failed {
            lines.append("Changes could not be determined: no comparable observation coverage.")
        } else if !input.failures.isEmpty || input.scopeStatus == .partial {
            lines.append("Failed")
            if input.failures.isEmpty {
                lines.append("  (partial coverage; details in af inspect)")
            } else {
                for failure in input.failures.prefix(5) {
                    lines.append(
                        "  [\(failure.phase.rawValue)] \(failure.path): \(failure.operation)"
                    )
                }
                if input.failures.count > 5 {
                    lines.append("  … +\(input.failures.count - 5) more (af inspect)")
                }
            }
            lines.append("")
            appendRankedSummaryBody(&lines, buckets: buckets)
            if !buckets.hasNotableChanges,
               collapsedDirs == 0,
               input.scopeStatus != .failed
            {
                lines.append("No changes detected in successfully observed paths.")
            }
        } else if !buckets.hasNotableChanges {
            if collapsedDirs > 0 {
                lines.append(
                    "No notable changes (+\(collapsedDirs) directory metadata — af inspect last)"
                )
            } else {
                lines.append("No changes detected in successfully observed paths.")
            }
        } else {
            appendRankedSummaryBody(&lines, buckets: buckets)
            if collapsedDirs > 0 {
                lines.append("")
                lines.append(
                    "(+\(collapsedDirs) directory metadata — af inspect last)"
                )
            }
        }

        if !input.contentLimitations.isEmpty {
            lines.append("")
            lines.append("Content limits")
            for limitation in input.contentLimitations.prefix(3) {
                lines.append("  \(limitation)")
            }
            if input.contentLimitations.count > 3 {
                lines.append(
                    "  … +\(input.contentLimitations.count - 3) more (af inspect)"
                )
            }
        }

        lines.append("")
        appendSaveFooter(&lines, input: input)
        return lines.joined(separator: "\n")
    }

    /// Summary order: semantic → CREATED → DELETED → MODIFIED.
    private static func appendRankedSummaryBody(
        _ lines: inout [String],
        buckets: ImportanceRanker.SummaryBuckets
    ) {
        appendSemanticSection(&lines, summaries: buckets.semanticSummaries, title: nil)
        appendChangeGroup(&lines, title: "CREATED", changes: buckets.created)
        appendChangeGroup(&lines, title: "DELETED", changes: buckets.deleted)
        appendChangeGroup(&lines, title: "MODIFIED", changes: buckets.modified)
    }

    // MARK: - Detailed

    private static func renderDetailed(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("AFTERSH RECEIPT")
        lines.append("")

        lines.append("Command")
        lines.append("  \(input.commandExecutable)")
        if input.argumentsOmitted {
            lines.append("Arguments")
            lines.append("  omitted")
        }

        if let termination = input.termination {
            switch termination {
            case .exited(let code):
                lines.append("Command exit")
                lines.append("  \(code)")
            case .signaled(let signal):
                lines.append("Command signal")
                lines.append("  \(signal) (wrapper exit \(termination.wrapperExitCode))")
            }
        }

        if let duration = input.commandDuration {
            lines.append("Command duration")
            lines.append(String(format: "  %.3fs", duration))
        }

        lines.append("Observation")
        lines.append("  \(input.scopeStatus.rawValue.uppercased())")
        lines.append("")

        lines.append("OBSERVATION SCOPE")
        lines.append("Watched")
        appendPathList(&lines, input.watchedPaths)
        lines.append("Excluded")
        if input.excludedPaths.isEmpty {
            lines.append("  none")
        } else {
            for exclusion in input.excludedPaths {
                lines.append("  \(exclusion.path) (\(exclusion.reason))")
            }
        }
        lines.append("Failed")
        if input.failures.isEmpty {
            lines.append("  none")
        } else {
            for failure in input.failures {
                lines.append(
                    "  [\(failure.phase.rawValue)] \(failure.path): \(failure.operation) (\(failure.code)) — \(failure.reason)"
                )
            }
        }
        lines.append("")

        if !input.semanticSummaries.isEmpty {
            lines.append("Semantic summaries")
            for summary in input.semanticSummaries {
                lines.append("  \(summary.message)  (\(summary.path))")
            }
            lines.append("")
        }

        lines.append("Observed between snapshots")
        appendChangesDetailed(&lines, status: input.scopeStatus, changes: input.changes)
        lines.append("")

        lines.append("Limits")
        lines.append(
            "  Metadata comparison; optional selected-file content (max \(ContentCapture.maxBytes) bytes)."
        )
        lines.append(
            "  Scans are non-atomic. Observation is not causation."
        )
        if !input.contentLimitations.isEmpty {
            for limitation in input.contentLimitations {
                lines.append("  \(limitation)")
            }
        }
        lines.append("")

        appendSaveFooter(&lines, input: input)
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared helpers

    private static func appendSemanticSection(
        _ lines: inout [String],
        summaries: [SemanticSummary],
        title: String?
    ) {
        guard !summaries.isEmpty else { return }
        if let title {
            lines.append(title)
        }
        for summary in summaries {
            lines.append(summary.message)
        }
        lines.append("")
    }

    private static func appendSaveFooter(_ lines: inout [String], input: Input) {
        if let id = input.savedReceiptId {
            lines.append("Receipt saved")
            lines.append("  \(id)")
        } else {
            lines.append("Receipt not saved.")
        }
    }

    private static func appendPathList(_ lines: inout [String], _ paths: [String]) {
        if paths.isEmpty {
            lines.append("  none")
        } else {
            for path in paths {
                lines.append("  \(path)")
            }
        }
    }

    private static func appendChangesDetailed(
        _ lines: inout [String],
        status: ObservationStatus,
        changes: [ObservedChange]
    ) {
        if status == .failed {
            lines.append("  Changes could not be determined: no comparable observation coverage.")
            return
        }
        if changes.isEmpty {
            lines.append("  No changes detected in successfully observed paths.")
            return
        }
        appendChangeGroups(&lines, changes: changes, emptyMessage: nil)
    }

    private static func appendChangeGroups(
        _ lines: inout [String],
        changes: [ObservedChange],
        emptyMessage: String?
    ) {
        if changes.isEmpty {
            if let emptyMessage {
                lines.append(emptyMessage)
            }
            return
        }
        let created = changes.filter { $0.kind == .created }
        let modified = changes.filter { $0.kind == .modified }
        let deleted = changes.filter { $0.kind == .deleted }
        appendChangeGroup(&lines, title: "CREATED", changes: created)
        appendChangeGroup(&lines, title: "MODIFIED", changes: modified)
        appendChangeGroup(&lines, title: "DELETED", changes: deleted)
    }

    private static func appendChangeGroup(
        _ lines: inout [String],
        title: String,
        changes: [ObservedChange]
    ) {
        guard !changes.isEmpty else { return }
        lines.append(title)
        for change in changes {
            lines.append("  \(change.path)")
        }
    }
}
