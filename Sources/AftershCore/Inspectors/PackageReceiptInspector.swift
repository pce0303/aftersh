import Foundation

public struct PackageReceiptFile: Equatable, Sendable {
    public var path: String
    public var modificationDate: Date

    public init(path: String, modificationDate: Date) {
        self.path = path
        self.modificationDate = modificationDate
    }
}

public struct PackageSourceError: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Read-only view of the macOS package receipt database.
public protocol PackageReceiptSource: Sendable {
    func listIDs() -> Result<Set<String>, PackageSourceError>
    func version(for id: String) -> String?
    /// Receipt plist per id. `nil` when no receipt directory can be read.
    func receiptModificationDates(for ids: Set<String>) -> [String: PackageReceiptFile]?
}

/// `pkgutil`-backed source for the default volume.
public struct PkgutilSource: PackageReceiptSource {
    public static let defaultReceiptDirectories = [
        "/var/db/receipts",
        "/Library/Apple/System/Library/Receipts",
    ]

    public var executable: String
    public var receiptDirectories: [String]
    public var timeout: TimeInterval

    public init(
        executable: String = "/usr/sbin/pkgutil",
        receiptDirectories: [String] = PkgutilSource.defaultReceiptDirectories,
        timeout: TimeInterval = 10
    ) {
        self.executable = executable
        self.receiptDirectories = receiptDirectories
        self.timeout = timeout
    }

    public func listIDs() -> Result<Set<String>, PackageSourceError> {
        switch ToolRunner.run(executable, arguments: ["--pkgs"], timeout: timeout) {
        case .success(let data):
            let ids = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .success(Set(ids))
        case .failure(let error):
            return .failure(error)
        }
    }

    public func version(for id: String) -> String? {
        guard case .success(let data) = ToolRunner.run(
            executable,
            arguments: ["--pkg-info-plist", id],
            timeout: timeout
        ) else {
            return nil
        }
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (plist as? [String: Any])?["pkg-version"] as? String
    }

    public func receiptModificationDates(for ids: Set<String>) -> [String: PackageReceiptFile]? {
        let fileManager = FileManager.default
        let readable = receiptDirectories.filter {
            (try? fileManager.contentsOfDirectory(atPath: $0)) != nil
        }
        guard !readable.isEmpty else { return nil }

        var files: [String: PackageReceiptFile] = [:]
        for id in ids {
            for directory in readable {
                let path = (directory as NSString).appendingPathComponent("\(id).plist")
                if let attributes = try? fileManager.attributesOfItem(atPath: path),
                   let date = attributes[.modificationDate] as? Date
                {
                    files[id] = PackageReceiptFile(path: path, modificationDate: date)
                    break
                }
            }
        }
        return files
    }
}

/// Runs a short-lived helper tool and returns its stdout, killing it after `timeout`.
enum ToolRunner {
    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }

    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Result<Data, PackageSourceError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return .failure(PackageSourceError("cannot run \(executable): \(error.localizedDescription)"))
        }

        // Drain stdout concurrently so a full pipe cannot block the tool.
        let box = OutputBox()
        let reading = DispatchGroup()
        reading.enter()
        let handle = output.fileHandleForReading
        DispatchQueue.global().async {
            box.data = handle.readDataToEndOfFile()
            reading.leave()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = reading.wait(timeout: .now() + 1)
            return .failure(PackageSourceError("\(executable) timed out after \(Int(timeout))s"))
        }
        _ = reading.wait(timeout: .now() + 1)

        guard process.terminationStatus == 0 else {
            return .failure(PackageSourceError("\(executable) exited with status \(process.terminationStatus)"))
        }
        return .success(box.data)
    }
}

/// Compares package receipts before and after a run. Reports receipts only; a receipt
/// does not prove an install succeeded, and other installers (Homebrew, npm) are invisible here.
public enum PackageReceiptInspector {
    public struct State: Equatable, Sendable {
        public var ids: Set<String>?
        public var receipts: [String: PackageReceiptFile]?
        public var limitation: String?
    }

    public static func capture(source: PackageReceiptSource) -> State {
        switch source.listIDs() {
        case .success(let ids):
            return State(ids: ids, receipts: source.receiptModificationDates(for: ids))
        case .failure(let error):
            return State(limitation: error.message)
        }
    }

    public static func summarize(
        before: State,
        after: State,
        source: PackageReceiptSource
    ) -> (summaries: [SemanticSummary], limitations: [String]) {
        var limitations: [String] = []
        if let message = before.limitation {
            limitations.append("pkgutil (before): \(message); package receipts not compared")
        }
        if let message = after.limitation {
            limitations.append("pkgutil (after): \(message); package receipts not compared")
        }
        guard let beforeIDs = before.ids, let afterIDs = after.ids else {
            return ([], limitations)
        }

        var summaries: [SemanticSummary] = []

        for id in afterIDs.subtracting(beforeIDs).sorted() {
            let version = source.version(for: id).map { " \($0)" } ?? ""
            summaries.append(
                SemanticSummary(
                    kind: "pkg_receipt_added",
                    message: "Package receipt added: \(id)\(version)",
                    path: after.receipts?[id]?.path ?? defaultPath(for: id)
                )
            )
        }

        if let beforeReceipts = before.receipts, let afterReceipts = after.receipts {
            for id in beforeIDs.intersection(afterIDs).sorted() {
                guard let old = beforeReceipts[id],
                      let new = afterReceipts[id],
                      old.modificationDate != new.modificationDate
                else {
                    continue
                }
                let version = source.version(for: id).map { " (version now \($0))" } ?? ""
                summaries.append(
                    SemanticSummary(
                        kind: "pkg_receipt_updated",
                        message: "Package receipt updated: \(id)\(version)",
                        path: new.path
                    )
                )
            }
        } else {
            limitations.append("same-ID package updates not compared: receipt directories unreadable")
        }

        for id in beforeIDs.subtracting(afterIDs).sorted() {
            summaries.append(
                SemanticSummary(
                    kind: "pkg_receipt_removed",
                    message: "Package receipt removed: \(id)",
                    path: before.receipts?[id]?.path ?? defaultPath(for: id)
                )
            )
        }

        return (summaries, limitations)
    }

    private static func defaultPath(for id: String) -> String {
        "/var/db/receipts/\(id).plist"
    }
}
