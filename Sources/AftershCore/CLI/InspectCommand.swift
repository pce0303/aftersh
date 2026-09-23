import ArgumentParser
import Foundation

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show a saved receipt by id or 'last'."
    )

    @Argument(help: "Receipt id, unambiguous prefix, or 'last'.")
    var id: String

    func run() throws {
        print("inspect: not implemented yet (\(id))")
    }
}
