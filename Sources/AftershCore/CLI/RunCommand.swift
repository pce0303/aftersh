import ArgumentParser
import Foundation

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command and record an observation receipt."
    )

    @Option(
        name: [.customShort("w"), .long],
        parsing: .singleValue,
        help: "Path to observe; repeatable. Required."
    )
    var watch: [String] = []

    @Option(
        name: [.customShort("e"), .long],
        parsing: .singleValue,
        help: "Path to exclude from observation; repeatable."
    )
    var exclude: [String] = []

    @Option(
        name: [.customShort("r"), .long],
        help: "Where to print the receipt summary: auto, stderr, or none."
    )
    var receiptOutput: ReceiptOutputMode = .auto

    @Flag(
        name: [.customShort("v"), .long],
        help: "Print the full detailed receipt after the run (default is a short summary)."
    )
    var verbose: Bool = false

    @Argument(
        parsing: .postTerminator,
        help: "Child command and arguments after --."
    )
    var command: [String] = []

    func run() throws {
        if watch.isEmpty {
            DiagnosticWriter.error("error: at least one --watch / -w path is required.")
            throw ExitCode(2)
        }

        if command.isEmpty {
            DiagnosticWriter.error("error: a child command is required after --.")
            throw ExitCode(2)
        }

        let manager = RunManager(
            processRunner: ProcessRunner(),
            receiptWriter: ReceiptWriter(mode: receiptOutput),
            verbosity: verbose ? .detailed : .summary
        )

        let code = manager.run(
            command: command,
            watchPaths: watch,
            excludePaths: exclude
        )
        throw ExitCode(code)
    }
}
