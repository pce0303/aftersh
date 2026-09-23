import Foundation

/// Renders a human-readable receipt from observation results.
public enum ReceiptRenderer {
    public struct Input: Sendable {
        public var commandExecutable: String
        public var termination: ProcessTermination?
        public var commandDuration: TimeInterval?
        public var scope: ObservationScope
        public var changes: [ObservedChange]

        public init(
            commandExecutable: String,
            termination: ProcessTermination?,
            commandDuration: TimeInterval? = nil,
            scope: ObservationScope,
            changes: [ObservedChange]
        ) {
            self.commandExecutable = commandExecutable
            self.termination = termination
            self.commandDuration = commandDuration
            self.scope = scope
            self.changes = changes
        }
    }

    public static func render(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("AFTERSH RECEIPT")
        lines.append("")

        lines.append("Command")
        lines.append("  \(input.commandExecutable)")

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
        lines.append("  \(input.scope.status.rawValue.uppercased())")
        lines.append("")

        lines.append("OBSERVATION SCOPE")
        lines.append("Watched")
        appendPathList(&lines, input.scope.watchedPaths)
        lines.append("Excluded")
        if input.scope.excludedPaths.isEmpty {
            lines.append("  none")
        } else {
            for exclusion in input.scope.excludedPaths {
                lines.append("  \(exclusion.path) (\(exclusion.reason))")
            }
        }
        lines.append("Failed")
        let failures = input.scope.failures
        if failures.isEmpty {
            lines.append("  none")
        } else {
            for failure in failures {
                lines.append(
                    "  [\(failure.phase.rawValue)] \(failure.path): \(failure.operation) (\(failure.code)) — \(failure.reason)"
                )
            }
        }
        lines.append("")

        lines.append("Observed between snapshots")
        appendChanges(&lines, status: input.scope.status, changes: input.changes)
        lines.append("")

        lines.append("Limits")
        lines.append(
            "  Metadata comparison only; scans are non-atomic. Observation is not causation."
        )
        lines.append("")
        lines.append("Receipt not saved yet.")

        return lines.joined(separator: "\n")
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

    private static func appendChanges(
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
