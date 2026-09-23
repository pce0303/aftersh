import Foundation

/// How a child process terminated.
public enum ProcessTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    /// Wrapper exit status: child code, or `128 + signal` when signaled.
    public var wrapperExitCode: Int32 {
        switch self {
        case .exited(let code):
            return code
        case .signaled(let signal):
            return 128 + signal
        }
    }
}

public enum ProcessLaunchError: Error, Equatable, Sendable {
    case executableNotFound(String)
    case notExecutable(String)
    case launchFailed(String)
}

/// Resolves an executable name through PATH or an explicit path.
public enum ExecutableResolver {
    public static func resolve(
        _ name: String,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) -> Result<String, ProcessLaunchError> {
        if name.contains("/") {
            return validateExplicitPath(name, fileManager: fileManager)
        }

        let path = pathEnvironment ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return .success(candidate)
            }
        }
        return .failure(.executableNotFound(name))
    }

    private static func validateExplicitPath(
        _ path: String,
        fileManager: FileManager
    ) -> Result<String, ProcessLaunchError> {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .failure(.executableNotFound(path))
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            return .failure(.notExecutable(path))
        }
        return .success(path)
    }
}

/// Executes argv with inherited streams, cwd, and environment.
public struct ProcessRunner: Sendable {
    public init() {}

    public func run(executable: String, arguments: [String]) throws -> ProcessTermination {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        // Leave environment and currentDirectoryURL nil to inherit.

        let session = SignalSession(process: process)
        session.install()
        defer { session.restore() }

        do {
            try process.run()
        } catch {
            throw ProcessLaunchError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        return session.termination()
    }
}

/// Handles SIGINT/SIGTERM while waiting for the child.
///
/// First terminal SIGINT is left for the foreground process group (no second
/// delivery from the wrapper). A second interrupt terminates the child.
/// SIGTERM to the wrapper is forwarded as SIGTERM to the child.
private final class SignalSession: @unchecked Sendable {
    private let process: Process
    private var previousSIGINT: sig_t?
    private var previousSIGTERM: sig_t?
    private var interruptCount = 0
    private let lock = NSLock()

    init(process: Process) {
        self.process = process
    }

    func install() {
        ActiveSignalSession.install(self)
        previousSIGINT = signal(SIGINT) { _ in
            ActiveSignalSession.current?.handleInterrupt()
        }
        previousSIGTERM = signal(SIGTERM) { _ in
            ActiveSignalSession.current?.handleTerminate()
        }
    }

    func restore() {
        if let previousSIGINT {
            signal(SIGINT, previousSIGINT)
        }
        if let previousSIGTERM {
            signal(SIGTERM, previousSIGTERM)
        }
        ActiveSignalSession.clear(self)
    }

    func termination() -> ProcessTermination {
        switch process.terminationReason {
        case .exit:
            return .exited(process.terminationStatus)
        case .uncaughtSignal:
            return .signaled(process.terminationStatus)
        @unknown default:
            return .exited(process.terminationStatus)
        }
    }

    fileprivate func handleInterrupt() {
        lock.lock()
        interruptCount += 1
        let count = interruptCount
        let running = process.isRunning
        lock.unlock()

        // First Ctrl-C: the terminal already signaled the foreground group.
        // Second Ctrl-C: abandon waiting and terminate the child.
        if count >= 2, running {
            process.terminate()
        }
    }

    fileprivate func handleTerminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

private enum ActiveSignalSession {
    private static let lock = NSLock()
    // Protected by `lock`; accessed from signal handlers on the same process.
    nonisolated(unsafe) private static var session: SignalSession?

    static var current: SignalSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    static func install(_ session: SignalSession) {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    static func clear(_ session: SignalSession) {
        lock.lock()
        if self.session === session {
            self.session = nil
        }
        lock.unlock()
    }
}
