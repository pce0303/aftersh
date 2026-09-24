import ArgumentParser
import Foundation

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List saved receipts."
    )

    func run() throws {
        let store = RunStore()
        let receipts = store.list(emitDiagnostics: true)
        print(ReceiptRenderer.renderHistory(receipts))
    }
}
