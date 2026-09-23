import ArgumentParser
import Foundation

/// Shared entry point for the `af` and `aftersh` executables.
public enum AftershMain {
    public static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            AftershRoot.main(["--help"])
            return
        }

        do {
            var command = try AftershRoot.parseAsRoot(args)
            try command.run()
        } catch let error as ExitCode {
            // Child status and explicit wrapper exits.
            Foundation.exit(error.rawValue)
        } catch {
            let code = AftershRoot.exitCode(for: error)
            if code.isSuccess {
                // Help / version / other clean exits.
                AftershRoot.exit(withError: error)
            }

            let message = AftershRoot.message(for: error)
            if !message.isEmpty {
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            // Invalid CLI usage before child launch uses exit 2.
            Foundation.exit(2)
        }
    }
}

struct AftershRoot: ParsableCommand {
    static var configuration: CommandConfiguration {
        let invoked = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        return CommandConfiguration(
            commandName: invoked,
            abstract: "Know what changed after sh.",
            discussion: """
                Wrap a command, observe scoped filesystem changes, and print a receipt.

                Execution is the default subcommand. Separate wrapper options from the \
                child command with --.
                """,
            subcommands: [RunCommand.self, HistoryCommand.self, InspectCommand.self],
            defaultSubcommand: RunCommand.self
        )
    }
}
