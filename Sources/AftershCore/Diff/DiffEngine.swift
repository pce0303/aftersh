import Foundation

public enum ChangeKind: String, Equatable, Sendable, Codable {
    case created
    case modified
    case deleted

    public var receiptLabel: String {
        switch self {
        case .created: return "CREATED"
        case .modified: return "MODIFIED"
        case .deleted: return "DELETED"
        }
    }
}

public struct ObservedChange: Equatable, Sendable, Codable {
    public var kind: ChangeKind
    public var path: String
    public var before: FileMetadata?
    public var after: FileMetadata?

    public init(
        kind: ChangeKind,
        path: String,
        before: FileMetadata? = nil,
        after: FileMetadata? = nil
    ) {
        self.kind = kind
        self.path = path
        self.before = before
        self.after = after
    }
}

/// Compares known endpoint states without inventing changes from scan gaps.
public enum DiffEngine {
    private enum EndpointState: Equatable {
        case present(FileMetadata)
        case absent
        case unknown
    }

    public static func diff(
        before: FilesystemSnapshot,
        after: FilesystemSnapshot
    ) -> [ObservedChange] {
        let paths = Set(before.entries.keys)
            .union(after.entries.keys)
            .union(before.coverage.knownAbsentPaths)
            .union(after.coverage.knownAbsentPaths)

        var changes: [ObservedChange] = []
        for path in paths.sorted() {
            let beforeState = state(of: path, in: before)
            let afterState = state(of: path, in: after)

            switch (beforeState, afterState) {
            case (.unknown, _), (_, .unknown):
                continue
            case (.absent, .present(let afterMeta)):
                changes.append(
                    ObservedChange(
                        kind: .created,
                        path: afterMeta.path,
                        before: nil,
                        after: afterMeta
                    )
                )
            case (.present(let beforeMeta), .absent):
                changes.append(
                    ObservedChange(
                        kind: .deleted,
                        path: beforeMeta.path,
                        before: beforeMeta,
                        after: nil
                    )
                )
            case (.present(let beforeMeta), .present(let afterMeta)):
                if !metadataEqual(beforeMeta, afterMeta) {
                    changes.append(
                        ObservedChange(
                            kind: .modified,
                            path: afterMeta.path,
                            before: beforeMeta,
                            after: afterMeta
                        )
                    )
                }
            case (.absent, .absent):
                continue
            }
        }
        return changes
    }

    private static func state(of path: String, in snapshot: FilesystemSnapshot) -> EndpointState {
        if isUnderUnknown(path, unknowns: snapshot.coverage.unknownSubtrees) {
            return .unknown
        }
        if let metadata = snapshot.entries[path] {
            return .present(metadata)
        }
        if isKnownAbsent(path, absents: snapshot.coverage.knownAbsentPaths) {
            return .absent
        }
        // Parent directory was listed successfully → missing child is verified absence.
        if parentWasListed(path, in: snapshot) {
            return .absent
        }
        return .unknown
    }

    private static func isUnderUnknown(_ path: String, unknowns: [String]) -> Bool {
        unknowns.contains { PathNormalizer.isEqualOrDescendant(of: $0, path: path) }
    }

    private static func isKnownAbsent(_ path: String, absents: [String]) -> Bool {
        absents.contains { PathNormalizer.isEqualOrDescendant(of: $0, path: path) }
    }

    private static func parentWasListed(_ path: String, in snapshot: FilesystemSnapshot) -> Bool {
        let parent = parentPath(path)
        guard parent != path else { return false }
        return snapshot.coverage.successfullyScannedPaths.contains(parent)
    }

    private static func parentPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private static func metadataEqual(_ lhs: FileMetadata, _ rhs: FileMetadata) -> Bool {
        lhs.type == rhs.type
            && lhs.size == rhs.size
            && lhs.modificationTime == rhs.modificationTime
            && lhs.permissions == rhs.permissions
            && lhs.symlinkTarget == rhs.symlinkTarget
    }
}
