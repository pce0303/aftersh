import Foundation

/// Fixed-priority classification for the live summary view.
/// Detailed/inspect output keeps the raw observation order unchanged.
public enum ImportanceRanker {
    public struct SummaryBuckets: Equatable, Sendable {
        public var semanticSummaries: [SemanticSummary]
        public var created: [ObservedChange]
        public var deleted: [ObservedChange]
        public var modified: [ObservedChange]
        public var collapsedDirectoryMetadataCount: Int

        public var hasNotableChanges: Bool {
            !semanticSummaries.isEmpty
                || !created.isEmpty
                || !deleted.isEmpty
                || !modified.isEmpty
        }

        public init(
            semanticSummaries: [SemanticSummary] = [],
            created: [ObservedChange] = [],
            deleted: [ObservedChange] = [],
            modified: [ObservedChange] = [],
            collapsedDirectoryMetadataCount: Int = 0
        ) {
            self.semanticSummaries = semanticSummaries
            self.created = created
            self.deleted = deleted
            self.modified = modified
            self.collapsedDirectoryMetadataCount = collapsedDirectoryMetadataCount
        }
    }

    /// Priority for summary: semantic → created/deleted → modified; directory metadata collapsed.
    public static func summarize(
        changes: [ObservedChange],
        semanticSummaries: [SemanticSummary]
    ) -> SummaryBuckets {
        let coveredPaths = Set(semanticSummaries.map(\.path))
        var created: [ObservedChange] = []
        var deleted: [ObservedChange] = []
        var modified: [ObservedChange] = []
        var collapsedDirs = 0

        for change in changes {
            if ReceiptRenderer.isDirectoryMetadataOnlyModify(change) {
                collapsedDirs += 1
                continue
            }
            if change.kind == .modified, coveredPaths.contains(change.path) {
                continue
            }
            switch change.kind {
            case .created:
                created.append(change)
            case .deleted:
                deleted.append(change)
            case .modified:
                modified.append(change)
            }
        }

        return SummaryBuckets(
            semanticSummaries: semanticSummaries,
            created: created,
            deleted: deleted,
            modified: modified,
            collapsedDirectoryMetadataCount: collapsedDirs
        )
    }
}
