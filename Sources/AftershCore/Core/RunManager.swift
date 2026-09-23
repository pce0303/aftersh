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
            let after = snapshotter.capture(
                watched: prepared.watched,
                excludeCanonical: prepared.excludeCanonical,
                phase: .after
            )
            let scope = makeScope(prepared: prepared, before: before, after: after)
            writeReceipt(scope: scope, commandExecutable: resolved, termination: nil)
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
        let scope = makeScope(prepared: prepared, before: before, after: after)
        writeReceipt(
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

    private func writeReceipt(
        scope: ObservationScope,
        commandExecutable: String,
        termination: ProcessTermination?,
        commandDuration: TimeInterval? = nil
    ) {
        let changes = DiffEngine.diff(before: scope.before, after: scope.after)
        let text = ReceiptRenderer.render(
            .init(
                commandExecutable: commandExecutable,
                termination: termination,
                commandDuration: commandDuration,
                scope: scope,
                changes: changes
            )
        )
        receiptWriter.write(text)
    }
}
