import Foundation

public enum RunStoreError: Error, Equatable, Sendable {
    case notFound(String)
    case ambiguousPrefix(String, matches: [String])
    case unsupportedSchema(Int)
    case io(String)
}

/// Atomically persists and retrieves versioned JSON receipts.
public struct RunStore: Sendable {
    public let directory: URL
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        directory: URL = AftershPaths.receiptsDirectory,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw RunStoreError.io("cannot create receipts directory: \(error.localizedDescription)")
        }
    }

    public func save(_ receipt: Receipt) throws {
        try ensureDirectory()
        let encoder = Self.makeEncoder()
        let data: Data
        do {
            data = try encoder.encode(receipt)
        } catch {
            throw RunStoreError.io("cannot encode receipt: \(error.localizedDescription)")
        }

        let finalURL = directory.appendingPathComponent("\(receipt.id).json")
        let tempName = ".\(receipt.id).tmp-\(UUID().uuidString)"
        let tempURL = directory.appendingPathComponent(tempName)

        do {
            if !fileManager.createFile(
                atPath: tempURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) {
                throw RunStoreError.io("cannot write temporary receipt file")
            }
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.removeItem(at: finalURL)
            }
            try fileManager.moveItem(at: tempURL, to: finalURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: finalURL.path
            )
        } catch let error as RunStoreError {
            try? fileManager.removeItem(at: tempURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw RunStoreError.io("cannot save receipt: \(error.localizedDescription)")
        }
    }

    /// Readable receipts newest-first (`endedAt`, then `id` as tie-breaker).
    public func list(emitDiagnostics: Bool = true) -> [Receipt] {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var receipts: [Receipt] = []
        for url in urls where url.pathExtension == "json" {
            do {
                let receipt = try decodeFile(at: url)
                receipts.append(receipt)
            } catch {
                if emitDiagnostics {
                    DiagnosticWriter.error(
                        "warning: skipping unreadable receipt \(url.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
        }

        return receipts.sorted { lhs, rhs in
            if lhs.endedAt != rhs.endedAt {
                return lhs.endedAt > rhs.endedAt
            }
            return lhs.id > rhs.id
        }
    }

    public func load(idOrPrefix: String) throws -> Receipt {
        if idOrPrefix == "last" {
            guard let latest = list(emitDiagnostics: false).first else {
                throw RunStoreError.notFound("last")
            }
            return latest
        }

        let all = list(emitDiagnostics: false)
        if let exact = all.first(where: { $0.id == idOrPrefix }) {
            return exact
        }

        let matches = all.filter { $0.id.hasPrefix(idOrPrefix) }
        if matches.count == 1 {
            return matches[0]
        }
        if matches.isEmpty {
            throw RunStoreError.notFound(idOrPrefix)
        }
        throw RunStoreError.ambiguousPrefix(idOrPrefix, matches: matches.map(\.id))
    }

    /// Deletes one receipt and returns its id. An exact `<id>.json` file is removed even when
    /// it cannot be decoded, so corrupt receipts can still be cleaned up.
    @discardableResult
    public func delete(idOrPrefix: String) throws -> String {
        let receiptId: String
        do {
            receiptId = try load(idOrPrefix: idOrPrefix).id
        } catch RunStoreError.notFound {
            guard Self.isPlainFileName(idOrPrefix) else {
                throw RunStoreError.notFound(idOrPrefix)
            }
            let rawURL = directory.appendingPathComponent("\(idOrPrefix).json")
            guard fileManager.fileExists(atPath: rawURL.path) else {
                throw RunStoreError.notFound(idOrPrefix)
            }
            try removeFile(at: rawURL)
            return idOrPrefix
        }

        guard let url = fileURL(forReceiptId: receiptId) else {
            throw RunStoreError.notFound(receiptId)
        }
        try removeFile(at: url)
        return receiptId
    }

    /// Deletes every visible `*.json` file in the receipts directory, readable or not.
    @discardableResult
    public func deleteAll() throws -> Int {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return 0
        }

        var count = 0
        for url in urls where url.pathExtension == "json" {
            try removeFile(at: url)
            count += 1
        }
        return count
    }

    private func fileURL(forReceiptId id: String) -> URL? {
        let direct = directory.appendingPathComponent("\(id).json")
        if fileManager.fileExists(atPath: direct.path) {
            return direct
        }
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.first { url in
            url.pathExtension == "json" && (try? decodeFile(at: url))?.id == id
        }
    }

    private func removeFile(at url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw RunStoreError.io(
                "cannot delete \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private static func isPlainFileName(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains("/")
            && value != "."
            && value != ".."
            && !value.hasPrefix(".")
    }

    private func decodeFile(at url: URL) throws -> Receipt {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RunStoreError.io(error.localizedDescription)
        }

        let decoder = Self.makeDecoder()
        let receipt: Receipt
        do {
            receipt = try decoder.decode(Receipt.self, from: data)
        } catch {
            throw RunStoreError.io("corrupt JSON: \(error.localizedDescription)")
        }

        if receipt.schemaVersion > AftershVersion.receiptSchemaVersion
            || receipt.schemaVersion < 1
        {
            throw RunStoreError.unsupportedSchema(receipt.schemaVersion)
        }
        return receipt
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            if let date = basic.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(string)"
            )
        }
        return decoder
    }
}

extension RunStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "receipt not found: \(id)"
        case .ambiguousPrefix(let prefix, let matches):
            return "ambiguous receipt id '\(prefix)'; matches: \(matches.joined(separator: ", "))"
        case .unsupportedSchema(let version):
            return "unsupported receipt schema version: \(version)"
        case .io(let message):
            return message
        }
    }
}
