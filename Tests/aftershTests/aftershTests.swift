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

@Test func runStoreDeleteByPrefixAndLast() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("aftersh-store-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let store = RunStore(directory: dir, fileManager: fm)
    try store.save(makeReceipt(id: "aaaa-1111", endedAt: Date(timeIntervalSince1970: 1)))
    try store.save(makeReceipt(id: "bbbb-2222", endedAt: Date(timeIntervalSince1970: 2)))
    try store.save(makeReceipt(id: "cccc-3333", endedAt: Date(timeIntervalSince1970: 3)))

    #expect(try store.delete(idOrPrefix: "aaaa") == "aaaa-1111")
    #expect(try store.delete(idOrPrefix: "last") == "cccc-3333")
    #expect(store.list(emitDiagnostics: false).map(\.id) == ["bbbb-2222"])

    do {
        try store.delete(idOrPrefix: "zzzz")
        Issue.record("expected notFound")
    } catch RunStoreError.notFound {
        // expected
    }
}

@Test func runStoreDeleteRejectsAmbiguousPrefix() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("aftersh-store-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let store = RunStore(directory: dir, fileManager: fm)
    try store.save(makeReceipt(id: "abcd-1111", endedAt: Date(timeIntervalSince1970: 1)))
    try store.save(makeReceipt(id: "abcd-2222", endedAt: Date(timeIntervalSince1970: 2)))

    do {
        try store.delete(idOrPrefix: "abcd")
        Issue.record("expected ambiguous prefix error")
    } catch RunStoreError.ambiguousPrefix {
        // expected
    }
    #expect(store.list(emitDiagnostics: false).count == 2)
}

@Test func runStoreDeleteCorruptFileAndDeleteAll() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("aftersh-store-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let store = RunStore(directory: dir, fileManager: fm)
    try store.save(makeReceipt(id: "good-0001", endedAt: Date(timeIntervalSince1970: 1)))
    try store.save(makeReceipt(id: "good-0002", endedAt: Date(timeIntervalSince1970: 2)))
    try "not-json".write(
        to: dir.appendingPathComponent("broken.json"),
        atomically: true,
        encoding: .utf8
    )
    try "keep".write(
        to: dir.appendingPathComponent(".hidden.json"),
        atomically: true,
        encoding: .utf8
    )

    #expect(try store.delete(idOrPrefix: "broken") == "broken")
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent("broken.json").path))

    do {
        try store.delete(idOrPrefix: "../escape")
        Issue.record("expected notFound for path-like id")
    } catch RunStoreError.notFound {
        // expected
    }

    #expect(try store.deleteAll() == 2)
    #expect(store.list(emitDiagnostics: false).isEmpty)
    #expect(fm.fileExists(atPath: dir.appendingPathComponent(".hidden.json").path))
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

@Test func summaryImportanceOrderSemanticCreatedDeletedModified() {
    let root = "/tmp/fixture"
    let zshrc = "/tmp/fixture/.zshrc"
    let created = "/tmp/fixture/new.txt"
    let deleted = "/tmp/fixture/gone.txt"
    let edited = "/tmp/fixture/edit.txt"
    let t0 = Date(timeIntervalSince1970: 1)
    let t1 = Date(timeIntervalSince1970: 2)

    let dirMod = ObservedChange(
        kind: .modified,
        path: root,
        before: FileMetadata(
            path: root,
            type: .directory,
            size: 64,
            modificationTime: t0,
            permissions: 0o755
        ),
        after: FileMetadata(
            path: root,
            type: .directory,
            size: 128,
            modificationTime: t1,
            permissions: 0o755
        )
    )

    let changes: [ObservedChange] = [
        ObservedChange(kind: .modified, path: edited, before: meta(edited), after: meta(edited, size: 9)),
        dirMod,
        ObservedChange(kind: .created, path: created, after: meta(created)),
        ObservedChange(
            kind: .modified,
            path: zshrc,
            before: meta(zshrc, size: 20),
            after: meta(zshrc, size: 28)
        ),
        ObservedChange(kind: .deleted, path: deleted, before: meta(deleted)),
    ]

    let buckets = ImportanceRanker.summarize(
        changes: changes,
        semanticSummaries: [
            SemanticSummary(
                kind: "path_entry_added",
                message: "PATH entry added: /new",
                path: zshrc
            )
        ]
    )
    #expect(buckets.semanticSummaries.map(\.message) == ["PATH entry added: /new"])
    #expect(buckets.created.map(\.path) == [created])
    #expect(buckets.deleted.map(\.path) == [deleted])
    #expect(buckets.modified.map(\.path) == [edited])
    #expect(buckets.collapsedDirectoryMetadataCount == 1)

    let summary = ReceiptRenderer.render(
        .init(
            commandExecutable: "/bin/sh",
            termination: .exited(0),
            scopeStatus: .complete,
            watchedPaths: [root],
            excludedPaths: [],
            failures: [],
            changes: changes,
            semanticSummaries: buckets.semanticSummaries,
            savedReceiptId: "rank-id",
            verbosity: .summary
        )
    )

    let pathIdx = summary.range(of: "PATH entry added: /new")!.lowerBound
    let createdIdx = summary.range(of: "CREATED")!.lowerBound
    let deletedIdx = summary.range(of: "DELETED")!.lowerBound
    let modifiedIdx = summary.range(of: "MODIFIED")!.lowerBound
    #expect(pathIdx < createdIdx)
    #expect(createdIdx < deletedIdx)
    #expect(deletedIdx < modifiedIdx)
    #expect(summary.contains(edited))
    #expect(!summary.contains(zshrc)) // covered by semantic; not listed under MODIFIED
    #expect(summary.contains("directory metadata"))

    let detailed = ReceiptRenderer.render(
        .init(
            commandExecutable: "/bin/sh",
            termination: .exited(0),
            scopeStatus: .complete,
            watchedPaths: [root],
            excludedPaths: [],
            failures: [],
            changes: changes,
            semanticSummaries: buckets.semanticSummaries,
            savedReceiptId: "rank-id",
            verbosity: .detailed
        )
    )
    // Detailed keeps full metadata including directory MODIFY and zshrc MODIFIED.
    #expect(detailed.contains("MODIFIED"))
    #expect(detailed.contains(root))
    #expect(detailed.contains(zshrc))
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

// MARK: - pkgutil

private struct FakePackageSource: PackageReceiptSource {
    var ids: Result<Set<String>, PackageSourceError>
    var versions: [String: String] = [:]
    var receipts: [String: PackageReceiptFile]? = [:]

    func listIDs() -> Result<Set<String>, PackageSourceError> { ids }
    func version(for id: String) -> String? { versions[id] }
    func receiptModificationDates(for ids: Set<String>) -> [String: PackageReceiptFile]? {
        receipts?.filter { ids.contains($0.key) }
    }
}

private func receiptFile(_ id: String, _ seconds: TimeInterval) -> PackageReceiptFile {
    PackageReceiptFile(
        path: "/var/db/receipts/\(id).plist",
        modificationDate: Date(timeIntervalSince1970: seconds)
    )
}

@Test func packageReceiptsAddedUpdatedRemoved() {
    let beforeSource = FakePackageSource(
        ids: .success(["com.example.kept", "com.example.updated", "com.example.gone"]),
        receipts: [
            "com.example.kept": receiptFile("com.example.kept", 1),
            "com.example.updated": receiptFile("com.example.updated", 1),
            "com.example.gone": receiptFile("com.example.gone", 1),
        ]
    )
    let afterSource = FakePackageSource(
        ids: .success(["com.example.kept", "com.example.updated", "com.example.new"]),
        versions: ["com.example.new": "1.2.3", "com.example.updated": "2.0"],
        receipts: [
            "com.example.kept": receiptFile("com.example.kept", 1),
            "com.example.updated": receiptFile("com.example.updated", 2),
            "com.example.new": receiptFile("com.example.new", 2),
        ]
    )

    let result = PackageReceiptInspector.summarize(
        before: PackageReceiptInspector.capture(source: beforeSource),
        after: PackageReceiptInspector.capture(source: afterSource),
        source: afterSource
    )
    #expect(result.limitations.isEmpty)
    #expect(result.summaries.map(\.message) == [
        "Package receipt added: com.example.new 1.2.3",
        "Package receipt updated: com.example.updated (version now 2.0)",
        "Package receipt removed: com.example.gone",
    ])
    #expect(result.summaries.map(\.kind) == [
        "pkg_receipt_added", "pkg_receipt_updated", "pkg_receipt_removed",
    ])
    #expect(result.summaries[0].path == "/var/db/receipts/com.example.new.plist")
}

@Test func packageReceiptsSourceFailureAndUnreadableReceipts() {
    let failing = FakePackageSource(ids: .failure(PackageSourceError("pkgutil exited with status 1")))
    let ok = FakePackageSource(ids: .success(["com.example.a"]), receipts: nil)

    let failed = PackageReceiptInspector.summarize(
        before: PackageReceiptInspector.capture(source: failing),
        after: PackageReceiptInspector.capture(source: ok),
        source: ok
    )
    #expect(failed.summaries.isEmpty)
    #expect(failed.limitations == [
        "pkgutil (before): pkgutil exited with status 1; package receipts not compared"
    ])

    let noReceipts = PackageReceiptInspector.summarize(
        before: PackageReceiptInspector.capture(source: ok),
        after: PackageReceiptInspector.capture(source: ok),
        source: ok
    )
    #expect(noReceipts.summaries.isEmpty)
    #expect(noReceipts.limitations == [
        "same-ID package updates not compared: receipt directories unreadable"
    ])
}

/// Returns the first ID set on the first `listIDs()` call and the second set afterwards.
private final class SteppingPackageSource: PackageReceiptSource, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let first: Set<String>
    private let second: Set<String>

    init(first: Set<String>, second: Set<String>) {
        self.first = first
        self.second = second
    }

    func listIDs() -> Result<Set<String>, PackageSourceError> {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return .success(calls == 1 ? first : second)
    }

    func version(for id: String) -> String? { "9.9" }

    func receiptModificationDates(for ids: Set<String>) -> [String: PackageReceiptFile]? {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, receiptFile($0, 1)) })
    }
}

@Test func runManagerPersistsPackageReceiptSummaries() throws {
    let fm = FileManager.default
    let watch = fm.temporaryDirectory.appendingPathComponent("aftersh-pkg-\(UUID().uuidString)")
    let storeDir = fm.temporaryDirectory.appendingPathComponent("aftersh-pkg-store-\(UUID().uuidString)")
    try fm.createDirectory(at: watch, withIntermediateDirectories: true)
    try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: watch)
        try? fm.removeItem(at: storeDir)
    }

    let manager = RunManager(
        processRunner: ProcessRunner(),
        receiptWriter: ReceiptWriter(mode: .none),
        runStore: RunStore(directory: storeDir, fileManager: fm),
        packageSource: SteppingPackageSource(
            first: ["com.example.base"],
            second: ["com.example.base", "com.example.tool"]
        )
    )
    #expect(manager.run(command: ["/usr/bin/true"], watchPaths: [watch.path], excludePaths: []) == 0)

    let receipt = try #require(RunStore(directory: storeDir, fileManager: fm).list(emitDiagnostics: false).first)
    #expect(receipt.semanticSummaries.map(\.message) == ["Package receipt added: com.example.tool 9.9"])
}

@Test func pkgutilSourceListsRealReceipts() {
    let source = PkgutilSource()
    guard case .success(let ids) = source.listIDs() else {
        Issue.record("pkgutil --pkgs failed")
        return
    }
    #expect(!ids.isEmpty)
    let receipts = source.receiptModificationDates(for: ids)
    #expect(receipts != nil)
    if let any = ids.sorted().first {
        #expect(source.version(for: any) != nil)
    }
}

// MARK: - FSEvents aggregation

private let eventRoot = NormalizedPath(display: "/tmp/watch", canonical: "/private/tmp/watch")

@Test func eventAggregatorMapsFiltersAndFindsTransientPaths() {
    var aggregator = EventAggregator(
        roots: [eventRoot],
        excludedCanonical: ["/private/tmp/watch/node_modules"]
    )
    let created = UInt32(kFSEventStreamEventFlagItemCreated)
    aggregator.ingest(path: "/private/tmp/watch/tmpfile", flags: created)
    aggregator.ingest(path: "/private/tmp/watch/kept.txt", flags: created)
    aggregator.ingest(path: "/private/tmp/watch/node_modules/x", flags: created)
    aggregator.ingest(path: "/private/tmp/other/y", flags: created)
    aggregator.ingest(path: "/private/tmp/watch/tmpfile", flags: created)
    aggregator.ingest(path: "", flags: UInt32(kFSEventStreamEventFlagHistoryDone))

    let observation = aggregator.observation(changes: [
        ObservedChange(kind: .created, path: "/tmp/watch/kept.txt", after: meta("/tmp/watch/kept.txt"))
    ])
    #expect(observation.status == .complete)
    #expect(observation.transientPaths == ["/tmp/watch/tmpfile"])
    #expect(observation.transientCount == 1)
    #expect(observation.gaps.isEmpty)
}

@Test func eventAggregatorRecordsDropGapsAndCap() {
    var aggregator = EventAggregator(roots: [eventRoot], excludedCanonical: [])
    aggregator.ingest(
        path: "/private/tmp/watch/sub",
        flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped)
    )
    var observation = aggregator.observation(changes: [])
    #expect(observation.status == .gapped)
    #expect(observation.gaps == [
        "/tmp/watch/sub: events coalesced; subtree must be rescanned",
        "/tmp/watch/sub: events dropped in kernel",
    ])

    var capped = EventAggregator(roots: [eventRoot], excludedCanonical: [])
    for index in 0...EventAggregator.maxPaths {
        capped.ingest(path: "/private/tmp/watch/f\(index)", flags: 0)
    }
    observation = capped.observation(changes: [])
    #expect(observation.status == .gapped)
    #expect(observation.transientCount == EventAggregator.maxPaths)
    #expect(observation.transientPaths.count == EventObservation.maxStoredTransientPaths)
    #expect(observation.gaps.contains { $0.contains("event path cap reached") })
}

@Test func eventAggregatorUnavailable() {
    var aggregator = EventAggregator(roots: [eventRoot], excludedCanonical: [])
    aggregator.ingest(path: "/private/tmp/watch/a", flags: 0)
    aggregator.markUnavailable("FSEvents stream could not start")
    let observation = aggregator.observation(changes: [])
    #expect(observation == EventObservation(status: .unavailable, gaps: ["FSEvents stream could not start"]))
}

// MARK: - launchd

private func writePlist(
    _ dictionary: [String: Any],
    to url: URL,
    format: PropertyListSerialization.PropertyListFormat = .xml
) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: dictionary,
        format: format,
        options: 0
    )
    try data.write(to: url)
}

private func makeLaunchAgentsDir() throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory
        .appendingPathComponent("aftersh-launchd-\(UUID().uuidString)")
        .appendingPathComponent("Library/LaunchAgents")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func launchdDomainDetection() {
    #expect(LaunchdInspector.domain(forPath: "/Users/x/Library/LaunchAgents/a.plist") == .agent)
    #expect(LaunchdInspector.domain(forPath: "/Library/LaunchDaemons/b.plist") == .daemon)
    #expect(LaunchdInspector.domain(forPath: "/Users/x/Library/LaunchAgents/a.txt") == nil)
    #expect(LaunchdInspector.domain(forPath: "/Users/x/Library/LaunchAgents/sub/a.plist") == nil)
    #expect(LaunchdInspector.domain(forPath: "/tmp/other/a.plist") == nil)
}

@Test func launchdChangedBinaryPlistAndRemoved() throws {
    let fm = FileManager.default
    let agents = try makeLaunchAgentsDir()
    defer { try? fm.removeItem(at: agents.deletingLastPathComponent().deletingLastPathComponent()) }

    let plist = agents.appendingPathComponent("com.example.test.plist")
    try writePlist(
        ["Label": "com.example.test", "ProgramArguments": ["/usr/local/bin/tool"]],
        to: plist
    )
    let before = FilesystemSnapshot(
        entries: [plist.path: meta(plist.path)],
        coverage: SnapshotCoverage(successfullyScannedPaths: [plist.path])
    )
    let beforeStates = LaunchdInspector.captureBefore(snapshot: before, fileManager: fm)
    #expect(beforeStates[plist.path]?.definition?.label == "com.example.test")

    try writePlist(
        [
            "Label": "com.example.test",
            "ProgramArguments": ["/usr/local/bin/tool"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
        ],
        to: plist,
        format: .binary
    )
    let modified = LaunchdInspector.summarize(
        changes: [ObservedChange(kind: .modified, path: plist.path, before: meta(plist.path), after: meta(plist.path, size: 2))],
        before: beforeStates,
        fileManager: fm
    )
    #expect(modified.limitations.isEmpty)
    #expect(modified.summaries.map(\.message) == [
        "LaunchAgent definition changed: com.example.test (RunAtLoad false -> true, KeepAlive off -> conditional)"
    ])
    #expect(modified.summaries.first?.kind == "launchd_definition_changed")

    try fm.removeItem(at: plist)
    let removed = LaunchdInspector.summarize(
        changes: [ObservedChange(kind: .deleted, path: plist.path, before: meta(plist.path))],
        before: beforeStates,
        fileManager: fm
    )
    #expect(removed.summaries.map(\.message) == ["LaunchAgent definition removed: com.example.test"])
}

@Test func launchdInvalidPlistRecordsLimitation() throws {
    let fm = FileManager.default
    let agents = try makeLaunchAgentsDir()
    defer { try? fm.removeItem(at: agents.deletingLastPathComponent().deletingLastPathComponent()) }

    let plist = agents.appendingPathComponent("broken.plist")
    try "not a plist".write(to: plist, atomically: true, encoding: .utf8)

    let result = LaunchdInspector.summarize(
        changes: [ObservedChange(kind: .created, path: plist.path, after: meta(plist.path))],
        before: [:],
        fileManager: fm
    )
    #expect(result.summaries.isEmpty)
    #expect(result.limitations.count == 1)
    #expect(result.limitations[0].contains("invalid property list"))
}

@Test func endToEndLaunchAgentObservedWithoutSecrets() throws {
    let fm = FileManager.default
    let agents = try makeLaunchAgentsDir()
    let fixtureRoot = agents.deletingLastPathComponent().deletingLastPathComponent()
    defer { try? fm.removeItem(at: fixtureRoot) }

    let template = fixtureRoot.appendingPathComponent("template.plist")
    try writePlist(
        [
            "Label": "com.example.test",
            "ProgramArguments": ["/usr/local/bin/tool", "--token", "SECRET_ARG_VALUE"],
            "RunAtLoad": true,
            "EnvironmentVariables": ["API_KEY": "SECRET_ENV_VALUE"],
        ],
        to: template
    )

    let storeDir = fm.temporaryDirectory.appendingPathComponent(
        "aftersh-launchd-store-\(UUID().uuidString)"
    )
    try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: storeDir) }

    let manager = RunManager(
        processRunner: ProcessRunner(),
        receiptWriter: ReceiptWriter(mode: .none),
        runStore: RunStore(directory: storeDir, fileManager: fm),
        verbosity: .summary
    )
    let destination = agents.appendingPathComponent("com.example.test.plist")
    let code = manager.run(
        command: ["/bin/cp", template.path, destination.path],
        watchPaths: [agents.path],
        excludePaths: []
    )
    #expect(code == 0)

    let receipts = RunStore(directory: storeDir, fileManager: fm).list(emitDiagnostics: false)
    #expect(receipts.count == 1)
    let receipt = receipts[0]
    #expect(receipt.semanticSummaries.map(\.message) == [
        "LaunchAgent definition observed: com.example.test (RunAtLoad; program /usr/local/bin/tool)"
    ])

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = String(decoding: try encoder.encode(receipt), as: UTF8.self)
    #expect(!json.contains("SECRET_ARG_VALUE"))
    #expect(!json.contains("SECRET_ENV_VALUE"))
    #expect(!json.contains("API_KEY"))

    let summary = ReceiptRenderer.render(receipt: receipt, verbosity: .summary)
    #expect(summary.contains("LaunchAgent definition observed: com.example.test"))
    #expect(!summary.contains("CREATED"))

    let detailed = ReceiptRenderer.render(receipt: receipt, verbosity: .detailed)
    #expect(detailed.contains("CREATED"))
    #expect(detailed.contains("com.example.test.plist"))
}

private func runEventsScenario(recordEvents: Bool) throws -> Receipt {
    let fm = FileManager.default
    let watch = fm.temporaryDirectory.appendingPathComponent("aftersh-events-\(UUID().uuidString)")
    let storeDir = fm.temporaryDirectory.appendingPathComponent("aftersh-events-store-\(UUID().uuidString)")
    try fm.createDirectory(at: watch, withIntermediateDirectories: true)
    try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: watch)
        try? fm.removeItem(at: storeDir)
    }

    let manager = RunManager(
        processRunner: ProcessRunner(),
        receiptWriter: ReceiptWriter(mode: .none),
        runStore: RunStore(directory: storeDir, fileManager: fm),
        recordEvents: recordEvents
    )
    let transient = watch.appendingPathComponent("a").path
    let code = manager.run(
        command: ["/bin/sh", "-c", "touch '\(transient)'; rm '\(transient)'"],
        watchPaths: [watch.path],
        excludePaths: []
    )
    #expect(code == 0)
    return try #require(RunStore(directory: storeDir, fileManager: fm).list(emitDiagnostics: false).first)
}

@Test func runManagerRecordsTransientEventPaths() throws {
    let receipt = try runEventsScenario(recordEvents: true)
    #expect(receipt.changes.allSatisfy(ReceiptRenderer.isDirectoryMetadataOnlyModify))

    let events = try #require(receipt.events)
    #expect(events.status == .complete)
    #expect(events.transientPaths.map { ($0 as NSString).lastPathComponent } == ["a"])
    #expect(events.transientCount == events.transientPaths.count)
    #expect(events.transientPaths.allSatisfy { !$0.hasPrefix("/private/") })

    let summary = ReceiptRenderer.render(receipt: receipt, verbosity: .summary)
    #expect(summary.contains("Events       COMPLETE"))
    #expect(summary.contains("+1 path seen only in events"))

    let detailed = ReceiptRenderer.render(receipt: receipt, verbosity: .detailed)
    #expect(detailed.contains("SEEN ONLY IN EVENTS"))
    #expect(detailed.contains("Events are supplemental"))
}

@Test func receiptOmitsEventsWithoutFlag() throws {
    let receipt = try runEventsScenario(recordEvents: false)
    #expect(receipt.events == nil)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = String(decoding: try encoder.encode(receipt), as: UTF8.self)
    #expect(!json.contains("\"events\""))

    let detailed = ReceiptRenderer.render(receipt: receipt, verbosity: .detailed)
    #expect(!detailed.contains("Events during run"))
    #expect(!detailed.contains("Events are supplemental"))
}

@Test func receiptDecodesWithoutEventsKey() throws {
    let receipt = try runEventsScenario(recordEvents: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var object = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(receipt)) as? [String: Any]
    )
    object.removeValue(forKey: "events")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Receipt.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.events == nil)
    #expect(decoded.id == receipt.id)
}
