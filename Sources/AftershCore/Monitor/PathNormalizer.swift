import Foundation

/// A path with a user-facing display form and a canonical comparison form.
public struct NormalizedPath: Equatable, Sendable {
    public var display: String
    public var canonical: String

    public init(display: String, canonical: String) {
        self.display = display
        self.canonical = canonical
    }
}

public enum PathNormalizer {
    /// Expand, standardize separators, and resolve existing ancestor aliases
    /// (e.g. `/tmp` → `/private/tmp`) while preserving the user-facing path.
    public static func normalize(
        _ raw: String,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default
    ) -> NormalizedPath {
        let expanded = expand(raw, workingDirectory: workingDirectory)
        let standardized = standardize(expanded)
        let canonical = canonicalize(standardized, fileManager: fileManager)
        return NormalizedPath(display: standardized, canonical: canonical)
    }

    public static func expand(
        _ raw: String,
        workingDirectory: String
    ) -> String {
        if raw.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if raw == "~" || raw.hasPrefix("~/") {
                return home + String(raw.dropFirst())
            }
        }
        if raw.hasPrefix("/") {
            return raw
        }
        return URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent(raw)
            .path
    }

    public static func standardize(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        var standardized = url.standardizedFileURL.path
        if standardized.count > 1, standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized.isEmpty ? "/" : standardized
    }

    /// Resolve symlinks for the longest existing ancestor; append the remainder.
    public static func canonicalize(
        _ path: String,
        fileManager: FileManager = .default
    ) -> String {
        let standardized = standardize(path)
        if standardized == "/" {
            return "/"
        }

        var components = URL(fileURLWithPath: standardized).pathComponents
        // pathComponents for "/" is ["/"]; for "/a/b" is ["/", "a", "b"]
        if components.first == "/" {
            components.removeFirst()
        }

        var resolved = "/"
        var remainder: [String] = []
        var foundGap = false

        for component in components {
            if foundGap {
                remainder.append(component)
                continue
            }
            let candidate = resolved == "/"
                ? "/" + component
                : resolved + "/" + component
            if fileManager.fileExists(atPath: candidate) {
                if let real = realPath(candidate) {
                    resolved = real
                } else {
                    resolved = candidate
                }
            } else {
                foundGap = true
                remainder.append(component)
            }
        }

        if remainder.isEmpty {
            return standardize(resolved)
        }
        let suffix = remainder.joined(separator: "/")
        let combined = resolved == "/" ? "/" + suffix : resolved + "/" + suffix
        return standardize(combined)
    }

    public static func isEqualOrDescendant(of ancestor: String, path: String) -> Bool {
        if path == ancestor { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    /// Keep broadest roots; drop duplicates and nested watch roots.
    public static func dedupeRoots(_ paths: [NormalizedPath]) -> [NormalizedPath] {
        let unique = uniquedByCanonical(paths)
        let sorted = unique.sorted { $0.canonical.count < $1.canonical.count }
        var kept: [NormalizedPath] = []
        for path in sorted {
            let nested = kept.contains {
                isEqualOrDescendant(of: $0.canonical, path: path.canonical)
            }
            if !nested {
                kept.append(path)
            }
        }
        return kept
    }

    public static func uniquedByCanonical(_ paths: [NormalizedPath]) -> [NormalizedPath] {
        var seen = Set<String>()
        var result: [NormalizedPath] = []
        for path in paths {
            if seen.insert(path.canonical).inserted {
                result.append(path)
            }
        }
        return result
    }

    private static func realPath(_ path: String) -> String? {
        path.withCString { ptr in
            guard let buffer = realpath(ptr, nil) else { return nil }
            defer { free(buffer) }
            return String(cString: buffer)
        }
    }
}
