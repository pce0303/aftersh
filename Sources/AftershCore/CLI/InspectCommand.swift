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
        let store = RunStore()
        do {
            let receipt = try store.load(idOrPrefix: id)
            print(ReceiptRenderer.render(receipt: receipt))
        } catch let error as RunStoreError {
            DiagnosticWriter.error("error: \(error.localizedDescription)")
            throw ExitCode(2)
        } catch {
            DiagnosticWriter.error("error: \(error.localizedDescription)")
            throw ExitCode(2)
        }
    }
}
