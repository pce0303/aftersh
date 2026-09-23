import ArgumentParser
import Foundation

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List saved receipts."
    )

    func run() throws {
        print("history: not implemented yet")
    }
}
