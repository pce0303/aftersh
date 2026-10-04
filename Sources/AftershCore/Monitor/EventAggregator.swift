import CoreServices
import Foundation

/// Persisted FSEvents evidence for one run. Events are supplemental: they show paths touched
/// under the watched scope during the run window, never which process touched them.
public struct EventObservation: Equatable, Sendable, Codable {
    public enum Status: String, Equatable, Sendable, Codable {
        case complete
        case gapped
        case unavailable
    }

    public static let maxStoredTransientPaths = 50

    public var status: Status
    /// Paths with events but no snapshot change (e.g. created and removed during the run).
    public var transientPaths: [String]
    public var transientCount: Int
    public var gaps: [String]

    public init(
        status: Status,
        transientPaths: [String] = [],
        transientCount: Int = 0,
        gaps: [String] = []
    ) {
        self.status = status
        self.transientPaths = transientPaths
        self.transientCount = transientCount
        self.gaps = gaps
    }
}

/// Collects FSEvents callbacks into bounded, scope-filtered evidence. Pure logic so it can be
/// tested without a live event stream.
public struct EventAggregator: Sendable {
    public static let maxPaths = 10_000
    static let maxGaps = 20

    static let gapFlags: [(flag: Int, reason: String)] = [
        (kFSEventStreamEventFlagMustScanSubDirs, "events coalesced; subtree must be rescanned"),
        (kFSEventStreamEventFlagUserDropped, "events dropped in user space"),
        (kFSEventStreamEventFlagKernelDropped, "events dropped in kernel"),
        (kFSEventStreamEventFlagEventIdsWrapped, "event ids wrapped"),
        (kFSEventStreamEventFlagRootChanged, "watched root moved or deleted"),
    ]

    /// Event-path prefixes mapped to the root's display form. Includes the `realpath` form
    /// because FSEvents reports fully resolved paths (e.g. `/private/tmp`).
    private let rootPrefixes: [(prefix: String, display: String)]
    private let excludedPrefixes: [String]
    private(set) var paths: Set<String> = []
    private(set) var gaps: [String] = []
    private var gapOverflow = 0
    private(set) var unavailableReason: String?

    public init(roots: [NormalizedPath], excludedCanonical: [String]) {
        var prefixes: [(prefix: String, display: String)] = []
        for root in roots {
            for form in Self.matchForms(root.canonical) where !prefixes.contains(where: { $0.prefix == form }) {
                prefixes.append((form, root.display))
            }
        }
        // Longest prefix first so nested forms map to the most specific root.
        rootPrefixes = prefixes.sorted { $0.prefix.count > $1.prefix.count }
        excludedPrefixes = excludedCanonical.flatMap(Self.matchForms)
    }

    /// Paths to hand to `FSEventStreamCreate`.
    public static func streamPaths(for roots: [NormalizedPath]) -> [String] {
        roots.map { realPath($0.canonical) ?? $0.canonical }
    }

    static func matchForms(_ path: String) -> [String] {
        guard let real = realPath(path), real != path else { return [path] }
        return [path, real]
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` is the resolved path FSEvents reports; it is mapped back to the watched root's
    /// display form so it lines up with snapshot diff paths.
    public mutating func ingest(path rawPath: String, flags: UInt32) {
        var canonical = rawPath
        while canonical.count > 1, canonical.hasSuffix("/") {
            canonical.removeLast()
        }
        let flagBits = Int(flags)

        if flagBits & kFSEventStreamEventFlagHistoryDone != 0 {
            return
        }

        for gap in Self.gapFlags where flagBits & gap.flag != 0 {
            recordGap("\(displayPath(forCanonical: canonical) ?? canonical): \(gap.reason)")
        }

        guard let display = displayPath(forCanonical: canonical) else { return }
        if excludedPrefixes.contains(where: {
            PathNormalizer.isEqualOrDescendant(of: $0, path: canonical)
        }) {
            return
        }
        if paths.contains(display) { return }
        if paths.count >= Self.maxPaths {
            recordGap("event path cap reached (\(Self.maxPaths) paths); later paths not recorded")
            return
        }
        paths.insert(display)
    }

    public mutating func markUnavailable(_ reason: String) {
        unavailableReason = reason
    }

    public func observation(changes: [ObservedChange]) -> EventObservation {
        if let unavailableReason {
            return EventObservation(status: .unavailable, gaps: [unavailableReason])
        }
        let changed = Set(changes.map(\.path))
        let transient = paths.subtracting(changed).sorted()
        var allGaps = gaps
        if gapOverflow > 0 {
            allGaps.append("… +\(gapOverflow) more gaps")
        }
        return EventObservation(
            status: allGaps.isEmpty ? .complete : .gapped,
            transientPaths: Array(transient.prefix(EventObservation.maxStoredTransientPaths)),
            transientCount: transient.count,
            gaps: allGaps
        )
    }

    mutating func recordGap(_ message: String) {
        if gaps.contains(message) { return }
        if gaps.count >= Self.maxGaps {
            gapOverflow += 1
            return
        }
        gaps.append(message)
    }

    private func displayPath(forCanonical canonical: String) -> String? {
        for root in rootPrefixes where PathNormalizer.isEqualOrDescendant(of: root.prefix, path: canonical) {
            return root.display + canonical.dropFirst(root.prefix.count)
        }
        return nil
    }
}
