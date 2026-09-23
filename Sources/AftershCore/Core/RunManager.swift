import Foundation

/// Coordinates a run and its independent outcomes.
struct RunManager: Sendable {
    private let processRunner: ProcessRunner
    private let receiptWriter: ReceiptWriter
    private let snapshotter: Snapshotter

    init(
        processRunner: ProcessRunner,
        receiptWriter: ReceiptWriter,
        snapshotter: Snapshotter = Snapshotter()
    ) {
        self.processRunner = processRunner
        self.receiptWriter = receiptWriter
        self.snapshotter = snapshotter
    }

    /// Runs the child command and returns the wrapper exit code.
    func run(
        command: [String],
        watchPaths: [String],
        excludePaths: [String]
    ) -> Int32 {
        guard let executableName = command.first else {
            DiagnosticWriter.error("error: a child command is required after --.")
            return 2
        }
        let arguments = Array(command.dropFirst())

        let prepared = snapshotter.prepareScope(
            watchPaths: watchPaths,
            excludePaths: excludePaths
        )
        guard !prepared.watched.isEmpty else {
            DiagnosticWriter.error("error: at least one --watch / -w path is required.")
            return 2
        }

        let resolved: String
        switch ExecutableResolver.resolve(executableName) {
        case .success(let path):
            resolved = path
        case .failure(.executableNotFound(let name)):
            DiagnosticWriter.error("error: executable not found: \(name)")
            return 127
        case .failure(.notExecutable(let path)):
            DiagnosticWriter.error("error: cannot execute: \(path)")
            return 126
        case .failure(.launchFailed(let message)):
            DiagnosticWriter.error("error: failed to launch: \(message)")
            return 126
        }

        let before = snapshotter.capture(
            watched: prepared.watched,
            excludeCanonical: prepared.excludeCanonical,
            phase: .before
        )

        let startedAt = Date()
        let termination: ProcessTermination
        do {
            termination = try processRunner.run(executable: resolved, arguments: arguments)
        } catch let error as ProcessLaunchError {
            // Still attempt an after snapshot so observation failures stay visible.
            let after = snapshotter.capture(
                watched: prepared.watched,
                excludeCanonical: prepared.excludeCanonical,
                phase: .after
            )
            let scope = makeScope(
                prepared: prepared,
                before: before,
                after: after
            )
            writeObservationSummary(scope: scope, commandExecutable: resolved, termination: nil)
            return launchExitCode(error)
        } catch {
            DiagnosticWriter.error("error: failed to launch: \(error.localizedDescription)")
            return 126
        }
        let endedAt = Date()

        let after = snapshotter.capture(
            watched: prepared.watched,
            excludeCanonical: prepared.excludeCanonical,
            phase: .after
        )
        let scope = makeScope(
            prepared: prepared,
            before: before,
            after: after
        )
        writeObservationSummary(
            scope: scope,
            commandExecutable: resolved,
            termination: termination,
            commandDuration: endedAt.timeIntervalSince(startedAt)
        )

        return termination.wrapperExitCode
    }

    private func makeScope(
        prepared: (watched: [NormalizedPath], exclusions: [PathExclusion], excludeCanonical: [String]),
        before: FilesystemSnapshot,
        after: FilesystemSnapshot
    ) -> ObservationScope {
        ObservationScope(
            watchedPaths: prepared.watched.map(\.display),
            watchedCanonicalPaths: prepared.watched.map(\.canonical),
            excludedPaths: prepared.exclusions,
            before: before,
            after: after,
            status: .from(before: before.coverage, after: after.coverage)
        )
    }

    private func launchExitCode(_ error: ProcessLaunchError) -> Int32 {
        switch error {
        case .executableNotFound(let name):
            DiagnosticWriter.error("error: executable not found: \(name)")
            return 127
        case .notExecutable(let path):
            DiagnosticWriter.error("error: cannot execute: \(path)")
            return 126
        case .launchFailed(let message):
            DiagnosticWriter.error("error: failed to launch: \(message)")
            return 126
        }
    }

    private func writeObservationSummary(
        scope: ObservationScope,
        commandExecutable: String,
        termination: ProcessTermination?,
        commandDuration: TimeInterval? = nil
    ) {
        var lines: [String] = []
        lines.append("AFTERSH OBSERVATION")
        lines.append("")
        lines.append("Command")
        lines.append("  \(commandExecutable)")
        if let termination {
            switch termination {
            case .exited(let code):
                lines.append("Command exit")
                lines.append("  \(code)")
            case .signaled(let signal):
                lines.append("Command signal")
                lines.append("  \(signal) (wrapper exit \(termination.wrapperExitCode))")
            }
        }
        if let commandDuration {
            lines.append("Command duration")
            lines.append(String(format: "  %.3fs", commandDuration))
        }
        lines.append("Observation")
        lines.append("  \(scope.status.rawValue.uppercased())")
        lines.append("")
        lines.append("OBSERVATION SCOPE")
        lines.append("Watched")
        if scope.watchedPaths.isEmpty {
            lines.append("  none")
        } else {
            for path in scope.watchedPaths {
                lines.append("  \(path)")
            }
        }
        lines.append("Excluded")
        if scope.excludedPaths.isEmpty {
            lines.append("  none")
        } else {
            for exclusion in scope.excludedPaths {
                lines.append("  \(exclusion.path) (\(exclusion.reason))")
            }
        }
        lines.append("Failed")
        let failures = scope.failures
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
        lines.append("Coverage")
        lines.append(
            "  before: \(scope.before.coverage.successfullyScannedPaths.count) scanned, \(scope.before.coverage.knownAbsentPaths.count) absent, \(scope.before.coverage.unknownSubtrees.count) unknown"
        )
        lines.append(
            "  after:  \(scope.after.coverage.successfullyScannedPaths.count) scanned, \(scope.after.coverage.knownAbsentPaths.count) absent, \(scope.after.coverage.unknownSubtrees.count) unknown"
        )
        lines.append(
            "  entries: \(scope.before.entries.count) → \(scope.after.entries.count)"
        )
        lines.append("")
        lines.append("Diff and receipt persistence are not implemented yet.")

        receiptWriter.write(lines.joined(separator: "\n"))
    }
}
