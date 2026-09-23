import Foundation

/// Coordinates a run and its independent outcomes.
///
/// v0.1 skeleton: transparent execution only. Snapshots, diff, and persistence
/// arrive in later stages; watch/exclude paths are accepted and reserved.
struct RunManager: Sendable {
    private let processRunner: ProcessRunner
    private let receiptWriter: ReceiptWriter

    init(processRunner: ProcessRunner, receiptWriter: ReceiptWriter) {
        self.processRunner = processRunner
        self.receiptWriter = receiptWriter
    }

    /// Runs the child command and returns the wrapper exit code.
    func run(
        command: [String],
        watchPaths: [String],
        excludePaths: [String]
    ) -> Int32 {
        _ = watchPaths
        _ = excludePaths
        _ = receiptWriter

        guard let executableName = command.first else {
            DiagnosticWriter.error("error: a child command is required after --.")
            return 2
        }
        let arguments = Array(command.dropFirst())

        let resolved: String
        switch ExecutableResolver.resolve(executableName) {
        case .success(let path):
            resolved = path
        case .failure(.executableNotFound(let name)):
            DiagnosticWriter.error("error: executable not found: \(name)")
            return 127
        case .failure(.notExecutable(let path)):
            DiagnosticWriter.error("error: cannot execute: \(path)")
            return 126
        case .failure(.launchFailed(let message)):
            DiagnosticWriter.error("error: failed to launch: \(message)")
            return 126
        }

        let termination: ProcessTermination
        do {
            termination = try processRunner.run(executable: resolved, arguments: arguments)
        } catch let error as ProcessLaunchError {
            switch error {
            case .executableNotFound(let name):
                DiagnosticWriter.error("error: executable not found: \(name)")
                return 127
            case .notExecutable(let path):
                DiagnosticWriter.error("error: cannot execute: \(path)")
                return 126
            case .launchFailed(let message):
                DiagnosticWriter.error("error: failed to launch: \(message)")
                return 126
            }
        } catch {
            DiagnosticWriter.error("error: failed to launch: \(error.localizedDescription)")
            return 126
        }

        return termination.wrapperExitCode
    }
}
