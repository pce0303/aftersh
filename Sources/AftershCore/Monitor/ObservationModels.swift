import Foundation

/// Where aftersh stores receipts and temporary scan data.
public enum AftershPaths {
    public static var dataHome: URL {
        // Prefer HOME so tests and wrappers can redirect storage.
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".local/share/aftersh", isDirectory: true)
    }

    public static var receiptsDirectory: URL {
        dataHome.appendingPathComponent("receipts", isDirectory: true)
    }

    public static var temporaryDirectory: URL {
        dataHome.appendingPathComponent("tmp", isDirectory: true)
    }
}

public enum EntryType: String, Equatable, Sendable, Codable {
    case file
    case directory
    case symlink
    case other
}

public struct FileMetadata: Equatable, Sendable, Codable {
    public var path: String
    public var type: EntryType
    public var size: Int64
    public var modificationTime: Date
    public var permissions: UInt16
    public var symlinkTarget: String?

    public init(
        path: String,
        type: EntryType,
        size: Int64,
        modificationTime: Date,
        permissions: UInt16,
        symlinkTarget: String? = nil
    ) {
        self.path = path
        self.type = type
        self.size = size
        self.modificationTime = modificationTime
        self.permissions = permissions
        self.symlinkTarget = symlinkTarget
    }
}

public enum ScanPhase: String, Equatable, Sendable, Codable {
    case before
    case after
}

public struct ScanFailure: Equatable, Sendable, Codable {
    public var path: String
    public var phase: ScanPhase
    public var operation: String
    public var reason: String
    public var code: String

    public init(
        path: String,
        phase: ScanPhase,
        operation: String,
        reason: String,
        code: String
    ) {
        self.path = path
        self.phase = phase
        self.operation = operation
        self.reason = reason
        self.code = code
    }
}

public struct SnapshotCoverage: Equatable, Sendable, Codable {
    public var startedAt: Date
    public var endedAt: Date
    public var successfullyScannedPaths: [String]
    public var knownAbsentPaths: [String]
    public var unknownSubtrees: [String]

    public init(
        startedAt: Date = Date(),
        endedAt: Date = Date(),
        successfullyScannedPaths: [String] = [],
        knownAbsentPaths: [String] = [],
        unknownSubtrees: [String] = []
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.successfullyScannedPaths = successfullyScannedPaths
        self.knownAbsentPaths = knownAbsentPaths
        self.unknownSubtrees = unknownSubtrees
    }

    public var hasComparableData: Bool {
        !successfullyScannedPaths.isEmpty || !knownAbsentPaths.isEmpty
    }

    public var hasUnknown: Bool {
        !unknownSubtrees.isEmpty
    }
}

public enum ObservationStatus: String, Equatable, Sendable, Codable {
    case complete
    case partial
    case failed

    /// Derive coverage status from the two endpoint scans.
    public static func from(before: SnapshotCoverage, after: SnapshotCoverage) -> ObservationStatus {
        guard before.hasComparableData, after.hasComparableData else {
            return .failed
        }
        if before.hasUnknown || after.hasUnknown {
            return .partial
        }
        return .complete
    }
}

public struct PathExclusion: Equatable, Sendable, Codable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct FilesystemSnapshot: Equatable, Sendable {
    /// Entries keyed by canonical path.
    public var entries: [String: FileMetadata]
    public var coverage: SnapshotCoverage
    public var failures: [ScanFailure]

    public init(
        entries: [String: FileMetadata] = [:],
        coverage: SnapshotCoverage = SnapshotCoverage(),
        failures: [ScanFailure] = []
    ) {
        self.entries = entries
        self.coverage = coverage
        self.failures = failures
    }
}

public struct ObservationScope: Equatable, Sendable {
    public var watchedPaths: [String]
    /// Canonical forms used for traversal and exclusion checks.
    public var watchedCanonicalPaths: [String]
    public var excludedPaths: [PathExclusion]
    public var before: FilesystemSnapshot
    public var after: FilesystemSnapshot
    public var status: ObservationStatus

    public init(
        watchedPaths: [String] = [],
        watchedCanonicalPaths: [String] = [],
        excludedPaths: [PathExclusion] = [],
        before: FilesystemSnapshot = FilesystemSnapshot(),
        after: FilesystemSnapshot = FilesystemSnapshot(),
        status: ObservationStatus = .failed
    ) {
        self.watchedPaths = watchedPaths
        self.watchedCanonicalPaths = watchedCanonicalPaths
        self.excludedPaths = excludedPaths
        self.before = before
        self.after = after
        self.status = status
    }

    public var failures: [ScanFailure] {
        before.failures + after.failures
    }
}
