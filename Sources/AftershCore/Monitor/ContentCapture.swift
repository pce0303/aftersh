import Foundation

/// Bounded text capture for explicitly selected files (v0.2).
public enum ContentCapture {
    public static let maxBytes = 64 * 1024

    public struct Snapshot: Equatable, Sendable {
        public var displayPath: String
        public var canonicalPath: String
        public var text: String?
        /// Why text was not captured (oversized, binary, missing, unreadable, …).
        public var limitation: String?

        public init(
            displayPath: String,
            canonicalPath: String,
            text: String? = nil,
            limitation: String? = nil
        ) {
            self.displayPath = displayPath
            self.canonicalPath = canonicalPath
            self.text = text
            self.limitation = limitation
        }
    }

    public struct SelectionError: Error, Equatable, Sendable {
        public var path: String
        public var message: String

        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
    }

    /// Normalize and ensure each content path lies under a watched root.
    public static func validateSelections(
        contentPaths: [String],
        watched: [NormalizedPath],
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default
    ) -> Result<[NormalizedPath], SelectionError> {
        var result: [NormalizedPath] = []
        var seen = Set<String>()

        for raw in contentPaths {
            let normalized = PathNormalizer.normalize(
                raw,
                workingDirectory: workingDirectory,
                fileManager: fileManager
            )
            if !seen.insert(normalized.canonical).inserted {
                continue
            }

            let underWatch = watched.contains {
                PathNormalizer.isEqualOrDescendant(of: $0.canonical, path: normalized.canonical)
            }
            guard underWatch else {
                return .failure(
                    SelectionError(
                        path: normalized.display,
                        message: "content path must be under a --watch root"
                    )
                )
            }
            result.append(normalized)
        }
        return .success(result)
    }

    public static func capture(
        path: NormalizedPath,
        fileManager: FileManager = .default
    ) -> Snapshot {
        let display = path.display
        let canonical = path.canonical

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: display, isDirectory: &isDirectory) else {
            return Snapshot(
                displayPath: display,
                canonicalPath: canonical,
                limitation: "path not present before/after capture"
            )
        }
        if isDirectory.boolValue {
            return Snapshot(
                displayPath: display,
                canonicalPath: canonical,
                limitation: "content capture requires a regular file"
            )
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fileManager.attributesOfItem(atPath: display)
        } catch {
            return Snapshot(
                displayPath: display,
                canonicalPath: canonical,
                limitation: "unreadable: \(error.localizedDescription)"
            )
        }

        if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
            return Snapshot(
                displayPath: display,
                canonicalPath: canonical,
                limitation: "content capture does not follow symlinks"
            )
        }

        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes {
            return Snapshot(
                displayPath: display,
                canonicalPath: canonical,
                limitation: "exceeds \(maxBytes) byte content limit"
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: display))
        } catch {
            return Snapshot(
                displayPath: display,
                canonicalPath: canonical,
                limitation: "unreadable: \(error.localizedDescription)"
            )
        }

        if data.contains(0) {
            return Snapshot(
                displayPath: display,
                canonicalPath: canonical,
                limitation: "file appears binary (NUL byte)"
            )
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return Snapshot(
                displayPath: display,
                canonicalPath: canonical,
                limitation: "not valid UTF-8 text"
            )
        }

        return Snapshot(
            displayPath: display,
            canonicalPath: canonical,
            text: text
        )
    }
}
