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
