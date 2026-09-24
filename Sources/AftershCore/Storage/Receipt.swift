import Foundation

public enum AftershVersion {
    public static let current = "0.1.0-dev"
    public static let receiptSchemaVersion = 1
}

/// Persisted observation summary (no full before/after entry maps).
public struct PersistedObservation: Equatable, Sendable, Codable {
    public var watchedPaths: [String]
    public var excludedPaths: [PathExclusion]
    public var status: ObservationStatus
    public var beforeCoverage: SnapshotCoverage
    public var afterCoverage: SnapshotCoverage
    public var failures: [ScanFailure]

    public init(
        watchedPaths: [String],
        excludedPaths: [PathExclusion],
        status: ObservationStatus,
        beforeCoverage: SnapshotCoverage,
        afterCoverage: SnapshotCoverage,
        failures: [ScanFailure]
    ) {
        self.watchedPaths = watchedPaths
        self.excludedPaths = excludedPaths
        self.status = status
        self.beforeCoverage = beforeCoverage
        self.afterCoverage = afterCoverage
        self.failures = failures
    }

    public init(scope: ObservationScope) {
        self.init(
            watchedPaths: scope.watchedPaths,
            excludedPaths: scope.excludedPaths,
            status: scope.status,
            beforeCoverage: scope.before.coverage,
            afterCoverage: scope.after.coverage,
            failures: scope.failures
        )
    }
}

/// Versioned, privacy-conscious receipt stored as JSON.
public struct Receipt: Equatable, Sendable, Codable {
    public var schemaVersion: Int
    public var aftershVersion: String
    public var id: String
    public var commandExecutable: String
    public var argumentsOmitted: Bool
    public var workingDirectory: String
    public var startedAt: Date
    public var endedAt: Date
    public var commandDuration: TimeInterval
    public var termination: ProcessTermination
    public var observation: PersistedObservation
    public var changes: [ObservedChange]
    public var interrupted: Bool

    public init(
        schemaVersion: Int = AftershVersion.receiptSchemaVersion,
        aftershVersion: String = AftershVersion.current,
        id: String = UUID().uuidString.lowercased(),
        commandExecutable: String,
        argumentsOmitted: Bool = true,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        startedAt: Date,
        endedAt: Date,
        commandDuration: TimeInterval,
        termination: ProcessTermination,
        observation: PersistedObservation,
        changes: [ObservedChange],
        interrupted: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.aftershVersion = aftershVersion
        self.id = id
        self.commandExecutable = commandExecutable
        self.argumentsOmitted = argumentsOmitted
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.commandDuration = commandDuration
        self.termination = termination
        self.observation = observation
        self.changes = changes
        self.interrupted = interrupted
    }
}
