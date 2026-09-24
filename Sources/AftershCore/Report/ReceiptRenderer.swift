import Foundation

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
        public var savedReceiptId: String?
        public var saveFailed: Bool

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
            savedReceiptId: String? = nil,
            saveFailed: Bool = false
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
            self.savedReceiptId = savedReceiptId
            self.saveFailed = saveFailed
        }

        public init(
            commandExecutable: String,
            termination: ProcessTermination?,
            commandDuration: TimeInterval? = nil,
            scope: ObservationScope,
            changes: [ObservedChange],
            savedReceiptId: String? = nil,
            saveFailed: Bool = false
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
                savedReceiptId: savedReceiptId,
                saveFailed: saveFailed
            )
        }
    }

    public static func render(_ input: Input) -> String {
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

        lines.append("Observed between snapshots")
        appendChanges(&lines, status: input.scopeStatus, changes: input.changes)
        lines.append("")

        lines.append("Limits")
        lines.append(
            "  Metadata comparison only; scans are non-atomic. Observation is not causation."
        )
        lines.append("")

        if let id = input.savedReceiptId {
            lines.append("Receipt saved")
            lines.append("  \(id)")
        } else if input.saveFailed {
            lines.append("Receipt not saved.")
        } else {
            lines.append("Receipt not saved.")
        }

        return lines.joined(separator: "\n")
    }

    public static func render(receipt: Receipt) -> String {
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
                savedReceiptId: receipt.id,
                saveFailed: false
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
