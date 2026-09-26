import Foundation
import Testing
@testable import AftershCore

@Test func terminationExitCodes() {
    #expect(ProcessTermination.exited(0).wrapperExitCode == 0)
    #expect(ProcessTermination.exited(1).wrapperExitCode == 1)
    #expect(ProcessTermination.signaled(2).wrapperExitCode == 130)
    #expect(ProcessTermination.signaled(15).wrapperExitCode == 143)
}

@Test func resolveExecutableOnPATH() {
    let result = ExecutableResolver.resolve("echo")
    guard case .success(let path) = result else {
        Issue.record("expected echo to resolve on PATH")
        return
    }
    #expect(path.hasSuffix("/echo"))
    #expect(FileManager.default.isExecutableFile(atPath: path))
}

@Test func resolveMissingExecutable() {
    let result = ExecutableResolver.resolve("aftersh-definitely-missing-binary-xyz")
    guard case .failure(.executableNotFound) = result else {
        Issue.record("expected executableNotFound")
        return
    }
}

@Test func resolveExplicitMissingPath() {
    let result = ExecutableResolver.resolve("/tmp/aftersh-missing-bin-xyz")
    guard case .failure(.executableNotFound) = result else {
        Issue.record("expected executableNotFound for missing path")
        return
    }
}

@Test func normalizeRelativePath() {
    let normalized = PathNormalizer.normalize(
        "foo/bar",
        workingDirectory: "/tmp/project"
    )
    #expect(normalized.display == "/tmp/project/foo/bar")
}

@Test func dedupeOverlappingWatchRoots() {
    let roots = PathNormalizer.dedupeRoots([
        NormalizedPath(display: "/tmp/a/b", canonical: "/tmp/a/b"),
        NormalizedPath(display: "/tmp/a", canonical: "/tmp/a"),
        NormalizedPath(display: "/tmp/a", canonical: "/tmp/a"),
    ])
    #expect(roots.map(\.canonical) == ["/tmp/a"])
}

@Test func observationStatusFromCoverage() {
    let complete = SnapshotCoverage(
        successfullyScannedPaths: ["/tmp/x"],
        knownAbsentPaths: [],
        unknownSubtrees: []
    )
    #expect(ObservationStatus.from(before: complete, after: complete) == .complete)

    let partialAfter = SnapshotCoverage(
        successfullyScannedPaths: ["/tmp/x"],
        knownAbsentPaths: [],
        unknownSubtrees: ["/tmp/x/secret"]
    )
    #expect(ObservationStatus.from(before: complete, after: partialAfter) == .partial)

    let empty = SnapshotCoverage()
    #expect(ObservationStatus.from(before: empty, after: complete) == .failed)
}

@Test func snapshotCreateAndAbsentRoot() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("aftersh-snap-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let snapshotter = Snapshotter(fileManager: fm)
    let prepared = snapshotter.prepareScope(
        watchPaths: [root.path],
        excludePaths: [],
        workingDirectory: root.path
    )

    let before = snapshotter.capture(
        watched: prepared.watched,
        excludeCanonical: prepared.excludeCanonical,
        phase: .before
    )
    #expect(before.coverage.unknownSubtrees.isEmpty)
    #expect(before.entries[prepared.watched[0].canonical]?.type == .directory)

    let file = root.appendingPathComponent("hello.txt")
    try "hi".write(to: file, atomically: true, encoding: .utf8)

    let after = snapshotter.capture(
        watched: prepared.watched,
        excludeCanonical: prepared.excludeCanonical,
        phase: .after
    )
    #expect(after.entries.count == before.entries.count + 1)
    #expect(ObservationStatus.from(before: before.coverage, after: after.coverage) == .complete)

    // Automatic storage exclusion is recorded.
    #expect(prepared.exclusions.contains { $0.reason.contains("automatic") })
}

@Test func snapshotVerifiedAbsentRoot() {
    let missing = "/tmp/aftersh-definitely-absent-\(UUID().uuidString)"
    let snapshotter = Snapshotter()
    let prepared = snapshotter.prepareScope(watchPaths: [missing], excludePaths: [])
    let snap = snapshotter.capture(
        watched: prepared.watched,
        excludeCanonical: prepared.excludeCanonical,
        phase: .before
    )
    #expect(snap.coverage.knownAbsentPaths.count == 1)
    #expect(snap.coverage.unknownSubtrees.isEmpty)
    #expect(snap.entries.isEmpty)
}

private func meta(
    _ path: String,
    size: Int64 = 1,
    mtime: Date = Date(timeIntervalSince1970: 100),
    permissions: UInt16 = 0o644
) -> FileMetadata {
    FileMetadata(
        path: path,
        type: .file,
        size: size,
        modificationTime: mtime,
        permissions: permissions
    )
}

@Test func diffDetectsCreateModifyDelete() {
    let root = "/tmp/watch"
    let file = "/tmp/watch/a.txt"
    let gone = "/tmp/watch/old.txt"
    let edited = "/tmp/watch/edit.txt"

    let before = FilesystemSnapshot(
        entries: [
            root: FileMetadata(
                path: root,
                type: .directory,
                size: 64,
                modificationTime: Date(timeIntervalSince1970: 1),
                permissions: 0o755
            ),
            gone: meta(gone),
            edited: meta(edited, size: 1),
        ],
        coverage: SnapshotCoverage(successfullyScannedPaths: [root, gone, edited])
    )
    let after = FilesystemSnapshot(
        entries: [
            root: FileMetadata(
                path: root,
                type: .directory,
                size: 64,
                modificationTime: Date(timeIntervalSince1970: 1),
                permissions: 0o755
            ),
            file: meta(file),
            edited: meta(edited, size: 2),
        ],
        coverage: SnapshotCoverage(successfullyScannedPaths: [root, file, edited])
    )

    let changes = DiffEngine.diff(before: before, after: after)
    #expect(changes.contains { $0.kind == .created && $0.path == file })
    #expect(changes.contains { $0.kind == .deleted && $0.path == gone })
    #expect(changes.contains { $0.kind == .modified && $0.path == edited })
}

@Test func diffSkipsDeleteWhenAfterUnknown() {
    let file = "/tmp/watch/a.txt"
    let before = FilesystemSnapshot(
        entries: [file: meta(file)],
        coverage: SnapshotCoverage(successfullyScannedPaths: [file])
    )
    let after = FilesystemSnapshot(
        entries: [:],
        coverage: SnapshotCoverage(
            successfullyScannedPaths: [],
            unknownSubtrees: ["/tmp/watch"]
        )
    )
    let changes = DiffEngine.diff(before: before, after: after)
    #expect(changes.isEmpty)
}

@Test func diffSkipsCreateWhenBeforeUnknown() {
    let file = "/tmp/watch/a.txt"
    let before = FilesystemSnapshot(
        entries: [:],
        coverage: SnapshotCoverage(unknownSubtrees: ["/tmp/watch"])
    )
    let after = FilesystemSnapshot(
        entries: [file: meta(file)],
        coverage: SnapshotCoverage(successfullyScannedPaths: [file])
    )
    let changes = DiffEngine.diff(before: before, after: after)
    #expect(changes.isEmpty)
}

@Test func diffEmptyWhenUnchanged() {
    let file = "/tmp/watch/a.txt"
    let snap = FilesystemSnapshot(
        entries: [file: meta(file)],
        coverage: SnapshotCoverage(successfullyScannedPaths: [file])
    )
    #expect(DiffEngine.diff(before: snap, after: snap).isEmpty)
}

@Test func receiptRendererFailedCoverageMessage() {
    let scope = ObservationScope(status: .failed)
    let text = ReceiptRenderer.render(
        .init(
            commandExecutable: "/bin/echo",
            termination: .exited(0),
            scope: scope,
            changes: [],
            saveFailed: true,
            verbosity: .detailed
        )
    )
    #expect(text.contains("AFTERSH RECEIPT"))
    #expect(text.contains("Changes could not be determined"))
    #expect(text.contains("Receipt not saved."))
}

@Test func receiptSummaryHidesDirectoryMetadataOnly() {
    let root = "/tmp/watch"
    let file = "/tmp/watch/a.txt"
    let t0 = Date(timeIntervalSince1970: 1)
    let t1 = Date(timeIntervalSince1970: 2)
    let dirBefore = FileMetadata(
        path: root,
        type: .directory,
        size: 64,
        modificationTime: t0,
        permissions: 0o755
    )
    let dirAfter = FileMetadata(
        path: root,
        type: .directory,
        size: 64,
        modificationTime: t1,
        permissions: 0o755
    )
    let created = ObservedChange(
        kind: .created,
        path: file,
        after: meta(file)
    )
    let dirMod = ObservedChange(
        kind: .modified,
        path: root,
        before: dirBefore,
        after: dirAfter
    )
    #expect(ReceiptRenderer.isDirectoryMetadataOnlyModify(dirMod))

    // Size may also change when children appear; still treated as directory metadata noise.
    let dirAfterSize = FileMetadata(
        path: root,
        type: .directory,
        size: 128,
        modificationTime: t1,
        permissions: 0o755
    )
    let dirModSize = ObservedChange(
        kind: .modified,
        path: root,
        before: dirBefore,
        after: dirAfterSize
    )
    #expect(ReceiptRenderer.isDirectoryMetadataOnlyModify(dirModSize))

    let summary = ReceiptRenderer.render(
        .init(
            commandExecutable: "/usr/bin/touch",
            termination: .exited(0),
            scopeStatus: .complete,
            watchedPaths: [root],
            excludedPaths: [],
            failures: [],
            changes: [created, dirModSize],
            savedReceiptId: "abc",
            verbosity: .summary
        )
    )
    #expect(summary.contains("CREATED"))
    #expect(summary.contains(file))
    #expect(summary.contains("directory metadata"))
    #expect(!summary.contains("MODIFIED"))
    #expect(!summary.contains("OBSERVATION SCOPE"))
    #expect(!summary.contains("Arguments"))

    let detailed = ReceiptRenderer.render(
        .init(
            commandExecutable: "/usr/bin/touch",
            termination: .exited(0),
            scopeStatus: .complete,
            watchedPaths: [root],
            excludedPaths: [],
            failures: [],
            changes: [created, dirModSize],
            savedReceiptId: "abc",
            verbosity: .detailed
        )
    )
    #expect(detailed.contains("OBSERVATION SCOPE"))
    #expect(detailed.contains("MODIFIED"))
    #expect(detailed.contains(root))
}

@Test func runStoreSaveReloadAndLast() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("aftersh-store-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let store = RunStore(directory: dir, fileManager: fm)
    let older = makeReceipt(id: "aaaa-1111", endedAt: Date(timeIntervalSince1970: 100))
    let newer = makeReceipt(id: "bbbb-2222", endedAt: Date(timeIntervalSince1970: 200))
    try store.save(older)
    try store.save(newer)

    let listed = store.list(emitDiagnostics: false)
    #expect(listed.map(\.id) == ["bbbb-2222", "aaaa-1111"])

    let last = try store.load(idOrPrefix: "last")
    #expect(last.id == "bbbb-2222")

    let byPrefix = try store.load(idOrPrefix: "aaaa")
    #expect(byPrefix.id == "aaaa-1111")
}

@Test func runStoreRejectsAmbiguousPrefix() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("aftersh-store-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let store = RunStore(directory: dir, fileManager: fm)
    try store.save(makeReceipt(id: "abcd-1111", endedAt: Date(timeIntervalSince1970: 1)))
    try store.save(makeReceipt(id: "abcd-2222", endedAt: Date(timeIntervalSince1970: 2)))

    do {
        _ = try store.load(idOrPrefix: "abcd")
        Issue.record("expected ambiguous prefix error")
    } catch RunStoreError.ambiguousPrefix {
        // expected
    }
}

@Test func runStoreSkipsCorruptAndUnsupported() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("aftersh-store-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let store = RunStore(directory: dir, fileManager: fm)
    try store.save(makeReceipt(id: "good-0001", endedAt: Date(timeIntervalSince1970: 50)))

    try "not-json".write(
        to: dir.appendingPathComponent("bad.json"),
        atomically: true,
        encoding: .utf8
    )

    var unsupported = makeReceipt(id: "future-0001", endedAt: Date(timeIntervalSince1970: 60))
    unsupported.schemaVersion = 99
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(unsupported)
    try data.write(to: dir.appendingPathComponent("future-0001.json"))

    let listed = store.list(emitDiagnostics: false)
    #expect(listed.map(\.id) == ["good-0001"])
}

private func makeReceipt(id: String, endedAt: Date) -> Receipt {
    Receipt(
        id: id,
        commandExecutable: "/bin/echo",
        startedAt: endedAt.addingTimeInterval(-1),
        endedAt: endedAt,
        commandDuration: 1,
        termination: .exited(0),
        observation: PersistedObservation(
            watchedPaths: ["/tmp"],
            excludedPaths: [],
            status: .complete,
            beforeCoverage: SnapshotCoverage(successfullyScannedPaths: ["/tmp"]),
            afterCoverage: SnapshotCoverage(successfullyScannedPaths: ["/tmp"]),
            failures: []
        ),
        changes: []
    )
}

@Test func processRunnerEchoExitZero() throws {
    let termination = try ProcessRunner().run(executable: "/bin/echo", arguments: ["hello"])
    #expect(termination == .exited(0))
}

@Test func processRunnerNonzeroExit() throws {
    let termination = try ProcessRunner().run(
        executable: "/bin/sh",
        arguments: ["-c", "exit 7"]
    )
    #expect(termination == .exited(7))
    #expect(termination.wrapperExitCode == 7)
}

@Test func processRunnerSignaledWrapperExitCode() {
    #expect(ProcessTermination.signaled(2).wrapperExitCode == 130)
}

@Test func contentCaptureRejectsOutsideWatch() {
    let watched = [
        NormalizedPath(display: "/tmp/watch", canonical: "/tmp/watch")
    ]
    let result = ContentCapture.validateSelections(
        contentPaths: ["/tmp/other/.zshrc"],
        watched: watched,
        workingDirectory: "/tmp"
    )
    guard case .failure(let error) = result else {
        Issue.record("expected selection failure")
        return
    }
    #expect(error.message.contains("under a --watch root"))
}

@Test func contentCaptureAcceptsUnderWatch() {
    let watched = [
        PathNormalizer.normalize("/tmp/watch", workingDirectory: "/tmp")
    ]
    let result = ContentCapture.validateSelections(
        contentPaths: ["/tmp/watch/.zshrc"],
        watched: watched,
        workingDirectory: "/tmp"
    )
    guard case .success(let paths) = result else {
        Issue.record("expected selection success")
        return
    }
    #expect(paths.count == 1)
    #expect(paths[0].display.hasSuffix("/.zshrc"))
}

@Test func pathSemanticDiffDetectsAddedEntry() {
    let before = "export PATH=/old\n"
    let after = "export PATH=/old:/new\n"
    let summaries = PathSemanticDiff.summarize(
        beforeText: before,
        afterText: after,
        displayPath: "/tmp/fixture/.zshrc"
    )
    #expect(summaries.count == 1)
    #expect(summaries[0].kind == "path_entry_added")
    #expect(summaries[0].message == "PATH entry added: /new")
    #expect(summaries[0].path == "/tmp/fixture/.zshrc")
}

@Test func pathSemanticDiffDetectsRemovedEntry() {
    let summaries = PathSemanticDiff.summarize(
        beforeText: "PATH=/old:/gone\n",
        afterText: "PATH=/old\n",
        displayPath: "/tmp/x"
    )
    #expect(summaries.map(\.message) == ["PATH entry removed: /gone"])
}

@Test func pathSemanticDiffIgnoresNonLiteralShell() {
    let summaries = PathSemanticDiff.summarize(
        beforeText: "PATH=$HOME/bin:$PATH\n",
        afterText: "PATH=$HOME/bin:$PATH:/extra\n",
        displayPath: "/tmp/x"
    )
    // Still literal PATH= lines — entries compared as opaque strings including $HOME.
    #expect(summaries.contains { $0.message == "PATH entry added: /extra" })
}

@Test func receiptSummaryShowsPathEntryWithoutRawDump() {
    let path = "/tmp/fixture/.zshrc"
    let summary = ReceiptRenderer.render(
        .init(
            commandExecutable: "/bin/sh",
            termination: .exited(0),
            scopeStatus: .complete,
            watchedPaths: ["/tmp/fixture"],
            excludedPaths: [],
            failures: [],
            changes: [
                ObservedChange(
                    kind: .modified,
                    path: path,
                    before: meta(path, size: 20),
                    after: meta(path, size: 28)
                )
            ],
            semanticSummaries: [
                SemanticSummary(
                    kind: "path_entry_added",
                    message: "PATH entry added: /new",
                    path: path
                )
            ],
            savedReceiptId: "demo-id",
            verbosity: .summary
        )
    )
    #expect(summary.contains("PATH entry added: /new"))
    #expect(!summary.contains("MODIFIED"))
    #expect(!summary.contains("export PATH"))
    #expect(!summary.contains("/old:/new"))
}

@Test func receiptOmitsRawContentFromJSON() throws {
    let receipt = Receipt(
        id: "sem-0001",
        commandExecutable: "/bin/sh",
        startedAt: Date(timeIntervalSince1970: 1),
        endedAt: Date(timeIntervalSince1970: 2),
        commandDuration: 1,
        termination: .exited(0),
        observation: PersistedObservation(
            watchedPaths: ["/tmp/fixture"],
            excludedPaths: [],
            status: .complete,
            beforeCoverage: SnapshotCoverage(successfullyScannedPaths: ["/tmp/fixture"]),
            afterCoverage: SnapshotCoverage(successfullyScannedPaths: ["/tmp/fixture"]),
            failures: []
        ),
        changes: [],
        semanticSummaries: [
            SemanticSummary(
                kind: "path_entry_added",
                message: "PATH entry added: /new",
                path: "/tmp/fixture/.zshrc"
            )
        ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(receipt)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("path_entry_added"))
    #expect(json.contains("PATH entry added:"))
    #expect(json.contains("semanticSummaries"))
    #expect(!json.contains("export PATH"))
    #expect(!json.contains("/old:/new"))
    #expect(!json.contains("\"text\""))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Receipt.self, from: data)
    #expect(decoded.semanticSummaries.map(\.message) == ["PATH entry added: /new"])
}

@Test func contentCaptureOversizedFallsBack() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "aftersh-content-\(UUID().uuidString)"
    )
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let file = root.appendingPathComponent("big.txt")
    let payload = Data(repeating: UInt8(ascii: "a"), count: ContentCapture.maxBytes + 1)
    try payload.write(to: file)

    let normalized = PathNormalizer.normalize(file.path, workingDirectory: root.path)
    let snap = ContentCapture.capture(path: normalized, fileManager: fm)
    #expect(snap.text == nil)
    #expect(snap.limitation?.contains("exceeds") == true)
}

@Test func endToEndLiteralPathFixture() throws {
    let fm = FileManager.default
    let fixture = fm.temporaryDirectory.appendingPathComponent(
        "aftersh-v02-\(UUID().uuidString)"
    )
    try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixture) }

    let zshrc = fixture.appendingPathComponent(".zshrc")
    try "export PATH=/old\n".write(to: zshrc, atomically: true, encoding: .utf8)

    let storeDir = fm.temporaryDirectory.appendingPathComponent(
        "aftersh-v02-store-\(UUID().uuidString)"
    )
    try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: storeDir) }

    let manager = RunManager(
        processRunner: ProcessRunner(),
        receiptWriter: ReceiptWriter(mode: .none),
        runStore: RunStore(directory: storeDir, fileManager: fm),
        verbosity: .summary
    )

    let code = manager.run(
        command: [
            "/bin/sh", "-c",
            "printf 'export PATH=/old:/new\\n' > \"$1\"",
            "sh",
            zshrc.path,
        ],
        watchPaths: [fixture.path],
        excludePaths: [],
        contentPaths: [zshrc.path]
    )
    #expect(code == 0)

    let receipts = RunStore(directory: storeDir, fileManager: fm).list(emitDiagnostics: false)
    #expect(receipts.count == 1)
    let receipt = receipts[0]
    #expect(receipt.semanticSummaries.contains {
        $0.message == "PATH entry added: /new"
    })

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = String(decoding: try encoder.encode(receipt), as: UTF8.self)
    #expect(!json.contains("export PATH=/old:/new"))
    #expect(!json.contains("\"text\""))
}
