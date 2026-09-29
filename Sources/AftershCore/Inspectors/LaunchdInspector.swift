import Foundation

/// Fields kept from a launchd property list. Everything else (remaining program arguments,
/// environment variables, sockets, …) is dropped because it can carry secrets.
public struct LaunchdDefinition: Equatable, Sendable {
    public enum KeepAlive: String, Equatable, Sendable {
        case off
        case on
        case conditional
    }

    public var label: String?
    public var program: String?
    public var runAtLoad: Bool
    public var keepAlive: KeepAlive
    public var hasStartInterval: Bool

    public init(
        label: String? = nil,
        program: String? = nil,
        runAtLoad: Bool = false,
        keepAlive: KeepAlive = .off,
        hasStartInterval: Bool = false
    ) {
        self.label = label
        self.program = program
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.hasStartInterval = hasStartInterval
    }

    public init(propertyList dictionary: [String: Any]) {
        label = dictionary["Label"] as? String
        if let program = dictionary["Program"] as? String {
            self.program = program
        } else if let arguments = dictionary["ProgramArguments"] as? [Any] {
            program = arguments.first as? String
        } else {
            program = nil
        }
        runAtLoad = (dictionary["RunAtLoad"] as? Bool) ?? false
        switch dictionary["KeepAlive"] {
        case let flag as Bool:
            keepAlive = flag ? .on : .off
        case is [String: Any]:
            keepAlive = .conditional
        default:
            keepAlive = .off
        }
        hasStartInterval = dictionary["StartInterval"] != nil
    }
}

/// Summarizes LaunchAgent / LaunchDaemon definitions that changed inside the watched scope.
/// Reports observed definitions only; it never claims a job is loaded or running.
public enum LaunchdInspector {
    public enum Domain: String, Sendable {
        case agent = "LaunchAgent"
        case daemon = "LaunchDaemon"
    }

    /// Parse result for one plist before the command ran.
    public struct BeforeState: Equatable, Sendable {
        public var definition: LaunchdDefinition?
        public var limitation: String?
    }

    public static func domain(forPath path: String) -> Domain? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "plist" else { return nil }
        switch url.deletingLastPathComponent().lastPathComponent {
        case "LaunchAgents":
            return .agent
        case "LaunchDaemons":
            return .daemon
        default:
            return nil
        }
    }

    /// Parse candidate plists present before execution, keyed by display path.
    public static func captureBefore(
        snapshot: FilesystemSnapshot,
        fileManager: FileManager = .default
    ) -> [String: BeforeState] {
        var states: [String: BeforeState] = [:]
        for metadata in snapshot.entries.values where domain(forPath: metadata.path) != nil {
            switch readDefinition(atPath: metadata.path, fileManager: fileManager) {
            case .success(let definition):
                states[metadata.path] = BeforeState(definition: definition)
            case .failure(let reason):
                states[metadata.path] = BeforeState(limitation: reason.message)
            }
        }
        return states
    }

    public static func summarize(
        changes: [ObservedChange],
        before: [String: BeforeState],
        fileManager: FileManager = .default
    ) -> (summaries: [SemanticSummary], limitations: [String]) {
        var summaries: [SemanticSummary] = []
        var limitations: [String] = []

        for change in changes {
            guard let domain = domain(forPath: change.path) else { continue }
            let fileName = URL(fileURLWithPath: change.path).lastPathComponent
            let beforeState = before[change.path]

            switch change.kind {
            case .created:
                switch readDefinition(atPath: change.path, fileManager: fileManager) {
                case .success(let definition):
                    summaries.append(
                        SemanticSummary(
                            kind: "launchd_definition_observed",
                            message: observedMessage(domain: domain, definition: definition, fileName: fileName),
                            path: change.path
                        )
                    )
                case .failure(let reason):
                    limitations.append("\(change.path): launchd plist not summarized: \(reason.message)")
                }

            case .modified:
                switch readDefinition(atPath: change.path, fileManager: fileManager) {
                case .success(let after):
                    if let beforeLimitation = beforeState?.limitation {
                        limitations.append(
                            "\(change.path) (before): launchd plist not summarized: \(beforeLimitation)"
                        )
                    }
                    summaries.append(
                        SemanticSummary(
                            kind: "launchd_definition_changed",
                            message: changedMessage(
                                domain: domain,
                                before: beforeState?.definition,
                                after: after,
                                fileName: fileName
                            ),
                            path: change.path
                        )
                    )
                case .failure(let reason):
                    limitations.append("\(change.path): launchd plist not summarized: \(reason.message)")
                }

            case .deleted:
                let name = beforeState?.definition?.label ?? fileName
                summaries.append(
                    SemanticSummary(
                        kind: "launchd_definition_removed",
                        message: "\(domain.rawValue) definition removed: \(name)",
                        path: change.path
                    )
                )
            }
        }
        return (summaries, limitations)
    }

    // MARK: - Messages

    private static func observedMessage(
        domain: Domain,
        definition: LaunchdDefinition,
        fileName: String
    ) -> String {
        let name = definition.label ?? fileName
        var flags: [String] = []
        if definition.runAtLoad { flags.append("RunAtLoad") }
        switch definition.keepAlive {
        case .on: flags.append("KeepAlive")
        case .conditional: flags.append("KeepAlive conditional")
        case .off: break
        }
        if definition.hasStartInterval { flags.append("StartInterval") }

        var details: [String] = []
        if !flags.isEmpty { details.append(flags.joined(separator: ", ")) }
        if let program = definition.program { details.append("program \(program)") }

        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: "; ")))"
        return "\(domain.rawValue) definition observed: \(name)\(suffix)"
    }

    private static func changedMessage(
        domain: Domain,
        before: LaunchdDefinition?,
        after: LaunchdDefinition,
        fileName: String
    ) -> String {
        let name = after.label ?? before?.label ?? fileName
        let prefix = "\(domain.rawValue) definition changed: \(name)"
        guard let before else {
            return prefix
        }

        var diffs: [String] = []
        if before.label != after.label {
            diffs.append("Label \(before.label ?? "none") -> \(after.label ?? "none")")
        }
        if before.program != after.program {
            diffs.append("program \(before.program ?? "none") -> \(after.program ?? "none")")
        }
        if before.runAtLoad != after.runAtLoad {
            diffs.append("RunAtLoad \(before.runAtLoad) -> \(after.runAtLoad)")
        }
        if before.keepAlive != after.keepAlive {
            diffs.append("KeepAlive \(before.keepAlive.rawValue) -> \(after.keepAlive.rawValue)")
        }
        if before.hasStartInterval != after.hasStartInterval {
            diffs.append(after.hasStartInterval ? "StartInterval added" : "StartInterval removed")
        }

        if diffs.isEmpty {
            return "\(prefix) (no summarized field changed)"
        }
        return "\(prefix) (\(diffs.joined(separator: ", ")))"
    }

    // MARK: - Reading

    struct ReadFailure: Error, Equatable {
        var message: String
    }

    static func readDefinition(
        atPath path: String,
        fileManager: FileManager
    ) -> Result<LaunchdDefinition, ReadFailure> {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: path)
        } catch {
            return .failure(ReadFailure(message: "unreadable: \(error.localizedDescription)"))
        }

        switch attributes[.type] as? FileAttributeType {
        case .typeRegular?:
            break
        case .typeSymbolicLink?:
            return .failure(ReadFailure(message: "symlink not followed"))
        default:
            return .failure(ReadFailure(message: "not a regular file"))
        }

        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if size > ContentCapture.maxBytes {
            return .failure(ReadFailure(message: "exceeds \(ContentCapture.maxBytes) byte limit"))
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return .failure(ReadFailure(message: "unreadable: \(error.localizedDescription)"))
        }

        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            return .failure(ReadFailure(message: "invalid property list"))
        }
        guard let dictionary = plist as? [String: Any] else {
            return .failure(ReadFailure(message: "property list is not a dictionary"))
        }
        return .success(LaunchdDefinition(propertyList: dictionary))
    }
}
