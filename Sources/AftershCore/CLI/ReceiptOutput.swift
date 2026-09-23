import ArgumentParser
import Foundation

enum ReceiptOutputMode: String, CaseIterable, ExpressibleByArgument, Sendable {
    case auto
    case stderr
    case none
}

/// Routes wrapper receipt text away from the child's stdout.
struct ReceiptWriter: Sendable {
    let mode: ReceiptOutputMode

    func write(_ message: String) {
        guard mode != .none else { return }
        let text = message.hasSuffix("\n") ? message : message + "\n"
        switch mode {
        case .none:
            return
        case .stderr:
            FileHandle.standardError.write(Data(text.utf8))
        case .auto:
            if let tty = FileHandle(forWritingAtPath: "/dev/tty") {
                tty.write(Data(text.utf8))
            } else {
                FileHandle.standardError.write(Data(text.utf8))
            }
        }
    }
}

/// Wrapper diagnostics always go to stderr, never child stdout.
enum DiagnosticWriter {
    static func error(_ message: String) {
        let text = message.hasSuffix("\n") ? message : message + "\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}
