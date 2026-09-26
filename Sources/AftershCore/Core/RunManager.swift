import Foundation

/// Coordinates a run and its independent outcomes.
struct RunManager: Sendable {
    private let processRunner: ProcessRunner
    private let receiptWriter: ReceiptWriter
    private let snapshotter: Snapshotter
    private let runStore: RunStore
    private let verbosity: ReceiptVerbosity

    init(
        processRunner: ProcessRunner,
        receiptWriter: ReceiptWriter,
        snapshotter: Snapshotter = Snapshotter(),
        runStore: RunStore = RunStore(),
        verbosity: ReceiptVerbosity = .summary
    ) {
        self.processRunner = processRunner
        self.receiptWriter = receiptWriter
        self.snapshotter = snapshotter
        self.runStore = runStore
        self.verbosity = verbosity
    }

    /// Runs the child command and returns the wrapper exit code.
    func run(
        command: [String],
        watchPaths: [String],
        excludePaths: [String],
        contentPaths: [String] = []
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

        let contentSelections: [NormalizedPath]
        switch ContentCapture.validateSelections(
            contentPaths: contentPaths,
            watched: prepared.watched
        ) {
        case .success(let paths):
            contentSelections = paths
        case .failure(let error):
            DiagnosticWriter.error("error: \(error.path): \(error.message)")
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

        // Capture originals before the child runs; required for content/semantic diffs.
        var beforeContent: [String: ContentCapture.Snapshot] = [:]
        for selection in contentSelections {
            let snap = ContentCapture.capture(path: selection)
            beforeContent[selection.canonical] = snap
        }

        let startedAt = Date()
        let termination: ProcessTermination
        do {
            termination = try processRunner.run(executable: resolved, arguments: arguments)
        } catch let error as ProcessLaunchError {
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
                termination: nil,
                startedAt: startedAt,
                endedAt: endedAt,
                persist: false,
                beforeContent: beforeContent,
                afterContent: [:],
                contentSelections: contentSelections
            )
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

        var afterContent: [String: ContentCapture.Snapshot] = [:]
        for selection in contentSelections {
            afterContent[selection.canonical] = ContentCapture.capture(path: selection)
        }

        let scope = makeScope(prepared: prepared, before: before, after: after)
        writeReceipt(
            scope: scope,
            commandExecutable: resolved,
            termination: termination,
            startedAt: startedAt,
            endedAt: endedAt,
            persist: true,
            beforeContent: beforeContent,
            afterContent: afterContent,
            contentSelections: contentSelections
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
        startedAt: Date,
        endedAt: Date,
        persist: Bool,
        beforeContent: [String: ContentCapture.Snapshot],
        afterContent: [String: ContentCapture.Snapshot],
        contentSelections: [NormalizedPath]
    ) {
        let changes = DiffEngine.diff(before: scope.before, after: scope.after)
        let duration = endedAt.timeIntervalSince(startedAt)

        var semanticSummaries: [SemanticSummary] = []
        var contentLimitations: [String] = []

        for selection in contentSelections {
            let beforeSnap = beforeContent[selection.canonical]
            let afterSnap = afterContent[selection.canonical]
            if let limitation = beforeSnap?.limitation {
                contentLimitations.append("\(selection.display) (before): \(limitation)")
            }
            if let limitation = afterSnap?.limitation {
                contentLimitations.append("\(selection.display) (after): \(limitation)")
            }
            semanticSummaries.append(
                contentsOf: PathSemanticDiff.summarize(
                    beforeText: beforeSnap?.text,
                    afterText: afterSnap?.text,
                    displayPath: selection.display
                )
            )
        }

        // Raw content stays only in local dictionaries above; do not copy into Receipt.
        var savedId: String?
        var saveFailed = false

        if persist, let termination {
            let receipt = Receipt(
                commandExecutable: commandExecutable,
                argumentsOmitted: true,
                startedAt: startedAt,
                endedAt: endedAt,
                commandDuration: duration,
                termination: termination,
                observation: PersistedObservation(scope: scope),
                changes: changes,
                semanticSummaries: semanticSummaries,
                contentLimitations: contentLimitations,
                interrupted: false
            )
            do {
                try runStore.save(receipt)
                savedId = receipt.id
            } catch {
                saveFailed = true
                DiagnosticWriter.error(
                    "error: failed to save receipt: \(error.localizedDescription)"
                )
            }
        } else {
            saveFailed = true
        }

        let text = ReceiptRenderer.render(
            .init(
                commandExecutable: commandExecutable,
                termination: termination,
                commandDuration: duration,
                scope: scope,
                changes: changes,
                semanticSummaries: semanticSummaries,
                contentLimitations: contentLimitations,
                savedReceiptId: savedId,
                saveFailed: saveFailed,
                verbosity: verbosity
            )
        )
        receiptWriter.write(text)
    }
}
