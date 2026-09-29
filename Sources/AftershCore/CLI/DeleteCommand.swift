import ArgumentParser
import Foundation

struct DeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a saved receipt by id, or all receipts with --all --yes."
    )

    @Argument(help: "Receipt id, unambiguous prefix, or 'last'.")
    var id: String?

    @Flag(name: .long, help: "Delete every saved receipt. Requires --yes.")
    var all: Bool = false

    @Flag(name: .long, help: "Confirm --all.")
    var yes: Bool = false

    func run() throws {
        let store = RunStore()

        if all {
            guard id == nil else {
                DiagnosticWriter.error("error: pass either a receipt id or --all, not both.")
                throw ExitCode(2)
            }
            guard yes else {
                DiagnosticWriter.error("error: --all deletes every saved receipt; add --yes to confirm.")
                throw ExitCode(2)
            }
            do {
                let count = try store.deleteAll()
                print("Deleted \(count) receipt\(count == 1 ? "" : "s")")
            } catch {
                DiagnosticWriter.error("error: \(error.localizedDescription)")
                throw ExitCode(2)
            }
            return
        }

        guard let id else {
            DiagnosticWriter.error("error: a receipt id, prefix, 'last', or --all --yes is required.")
            throw ExitCode(2)
        }

        do {
            let deleted = try store.delete(idOrPrefix: id)
            print("Deleted \(deleted)")
        } catch {
            DiagnosticWriter.error("error: \(error.localizedDescription)")
            throw ExitCode(2)
        }
    }
}
