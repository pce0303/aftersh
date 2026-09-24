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
            saveFailed: true
        )
    )
    #expect(text.contains("AFTERSH RECEIPT"))
    #expect(text.contains("Changes could not be determined"))
    #expect(text.contains("Receipt not saved."))
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
