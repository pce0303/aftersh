import Foundation

/// Captures scoped filesystem metadata without following leaf symlinks.
public struct Snapshotter: Sendable {
    // FileManager is thread-safe for shared default usage but not marked Sendable.
    nonisolated(unsafe) private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Build watch/exclude lists, including the automatic aftersh storage exclusion.
    public func prepareScope(
        watchPaths: [String],
        excludePaths: [String],
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) -> (
        watched: [NormalizedPath],
        exclusions: [PathExclusion],
        excludeCanonical: [String]
    ) {
        let watched = PathNormalizer.dedupeRoots(
            watchPaths.map {
                PathNormalizer.normalize($0, workingDirectory: workingDirectory, fileManager: fileManager)
            }
        )

        var exclusions: [PathExclusion] = []
        var excludeCanonical: [String] = []

        for raw in excludePaths {
            let normalized = PathNormalizer.normalize(
                raw,
                workingDirectory: workingDirectory,
                fileManager: fileManager
            )
            if !excludeCanonical.contains(normalized.canonical) {
                excludeCanonical.append(normalized.canonical)
                exclusions.append(PathExclusion(path: normalized.display, reason: "user exclude"))
            }
        }

        let storage = PathNormalizer.normalize(
            AftershPaths.dataHome.path,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        if !excludeCanonical.contains(where: {
            PathNormalizer.isEqualOrDescendant(of: $0, path: storage.canonical)
        }) {
            excludeCanonical.append(storage.canonical)
            exclusions.append(
                PathExclusion(path: storage.display, reason: "automatic: aftersh storage")
            )
        }

        return (watched, exclusions, excludeCanonical)
    }

    public func capture(
        watched: [NormalizedPath],
        excludeCanonical: [String],
        phase: ScanPhase
    ) -> FilesystemSnapshot {
        let startedAt = Date()
        var entries: [String: FileMetadata] = [:]
        var successfullyScannedPaths: [String] = []
        var knownAbsentPaths: [String] = []
        var unknownSubtrees: [String] = []
        var failures: [ScanFailure] = []

        for root in watched {
            if isExcluded(root.canonical, excludes: excludeCanonical) {
                continue
            }

            scanPath(
                displayPath: root.display,
                canonicalPath: root.canonical,
                excludeCanonical: excludeCanonical,
                phase: phase,
                entries: &entries,
                successfullyScannedPaths: &successfullyScannedPaths,
                knownAbsentPaths: &knownAbsentPaths,
                unknownSubtrees: &unknownSubtrees,
                failures: &failures
            )
        }

        let endedAt = Date()
        let coverage = SnapshotCoverage(
            startedAt: startedAt,
            endedAt: endedAt,
            successfullyScannedPaths: successfullyScannedPaths.sorted(),
            knownAbsentPaths: knownAbsentPaths.sorted(),
            unknownSubtrees: unknownSubtrees.sorted()
        )
        return FilesystemSnapshot(entries: entries, coverage: coverage, failures: failures)
    }

    private func scanPath(
        displayPath: String,
        canonicalPath: String,
        excludeCanonical: [String],
        phase: ScanPhase,
        entries: inout [String: FileMetadata],
        successfullyScannedPaths: inout [String],
        knownAbsentPaths: inout [String],
        unknownSubtrees: inout [String],
        failures: inout [ScanFailure]
    ) {
        if isExcluded(canonicalPath, excludes: excludeCanonical) {
            return
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: displayPath)
        } catch {
            if isVerifiedAbsent(displayPath: displayPath) {
                knownAbsentPaths.append(canonicalPath)
                return
            }

            unknownSubtrees.append(canonicalPath)
            failures.append(
                ScanFailure(
                    path: displayPath,
                    phase: phase,
                    operation: "stat",
                    reason: error.localizedDescription,
                    code: "stat_failed"
                )
            )
            return
        }

        guard let metadata = metadata(
            displayPath: displayPath,
            canonicalPath: canonicalPath,
            attributes: attributes,
            phase: phase,
            failures: &failures
        ) else {
            unknownSubtrees.append(canonicalPath)
            return
        }

        entries[canonicalPath] = metadata
        successfullyScannedPaths.append(canonicalPath)

        // Never follow symlinks into other trees; record them as leaves.
        guard metadata.type == .directory else {
            return
        }

        let children: [String]
        do {
            children = try fileManager.contentsOfDirectory(atPath: displayPath)
        } catch {
            unknownSubtrees.append(canonicalPath)
            failures.append(
                ScanFailure(
                    path: displayPath,
                    phase: phase,
                    operation: "list",
                    reason: error.localizedDescription,
                    code: "list_failed"
                )
            )
            return
        }

        for childName in children.sorted() {
            let childDisplay = URL(fileURLWithPath: displayPath, isDirectory: true)
                .appendingPathComponent(childName)
                .path
            let childCanonical = PathNormalizer.canonicalize(childDisplay, fileManager: fileManager)
            scanPath(
                displayPath: childDisplay,
                canonicalPath: childCanonical,
                excludeCanonical: excludeCanonical,
                phase: phase,
                entries: &entries,
                successfullyScannedPaths: &successfullyScannedPaths,
                knownAbsentPaths: &knownAbsentPaths,
                unknownSubtrees: &unknownSubtrees,
                failures: &failures
            )
        }
    }

    private func metadata(
        displayPath: String,
        canonicalPath: String,
        attributes: [FileAttributeKey: Any],
        phase: ScanPhase,
        failures: inout [ScanFailure]
    ) -> FileMetadata? {
        let type = entryType(from: attributes[.type] as? FileAttributeType)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationTime = attributes[.modificationDate] as? Date ?? Date.distantPast
        let permissions = UInt16((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)

        var symlinkTarget: String?
        if type == .symlink {
            do {
                symlinkTarget = try fileManager.destinationOfSymbolicLink(atPath: displayPath)
            } catch {
                failures.append(
                    ScanFailure(
                        path: displayPath,
                        phase: phase,
                        operation: "readlink",
                        reason: error.localizedDescription,
                        code: "readlink_failed"
                    )
                )
            }
        }

        return FileMetadata(
            path: canonicalPath,
            type: type,
            size: size,
            modificationTime: modificationTime,
            permissions: permissions,
            symlinkTarget: symlinkTarget
        )
    }

    private func entryType(from type: FileAttributeType?) -> EntryType {
        switch type {
        case .typeDirectory:
            return .directory
        case .typeSymbolicLink:
            return .symlink
        case .typeRegular:
            return .file
        default:
            return .other
        }
    }

    /// Absence is verified only when a readable parent confirms the name is missing.
    private func isVerifiedAbsent(displayPath: String) -> Bool {
        let url = URL(fileURLWithPath: displayPath)
        let parent = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        guard !name.isEmpty, parent != displayPath else {
            return false
        }

        do {
            _ = try fileManager.attributesOfItem(atPath: parent)
        } catch {
            return false
        }

        do {
            let children = try fileManager.contentsOfDirectory(atPath: parent)
            return !children.contains(name)
        } catch {
            return false
        }
    }

    private func isExcluded(_ canonicalPath: String, excludes: [String]) -> Bool {
        excludes.contains { PathNormalizer.isEqualOrDescendant(of: $0, path: canonicalPath) }
    }
}
