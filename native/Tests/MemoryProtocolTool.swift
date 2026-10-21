import Foundation
import Darwin

/// Small fixture-only driver for tests/integration_memory_protocol.py.
/// Always requires an explicit directory; never opens the default user store.
@main
private enum MemoryProtocolTool {
    private static func usage() throws -> Never {
        throw MacWordMemoryError(message: "Usage: MemoryProtocolTool DIRECTORY read|remember TEXT INPUT|forget TEXT|block TEXT|unblock TEXT|clear|learning 0|1|is-blocked TEXT")
    }

    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count >= 2 else { try usage() }
            let store = MacWordMemoryFileStore(directory: URL(fileURLWithPath: arguments[0], isDirectory: true))
            let payload = Array(arguments.dropFirst(2))
            switch arguments[1] {
            case "read": guard payload.isEmpty else { try usage() }
            case "remember":
                guard payload.count == 2 else { try usage() }
                try store.remember(text: payload[0], input: payload[1])
            case "forget":
                guard payload.count == 1 else { try usage() }
                try store.forget(text: payload[0])
            case "block":
                guard payload.count == 1 else { try usage() }
                try store.block(text: payload[0])
            case "unblock":
                guard payload.count == 1 else { try usage() }
                try store.unblock(text: payload[0])
            case "clear":
                guard payload.isEmpty else { try usage() }
                try store.clearLearned()
            case "learning":
                guard payload.count == 1, payload[0] == "0" || payload[0] == "1" else { try usage() }
                try store.setLearningEnabled(payload[0] == "1")
            case "is-blocked":
                guard payload.count == 1 else { try usage() }
            default: try usage()
            }
            let snapshot = try store.read()
            let output: [String: Any]
            if arguments[1] == "is-blocked" {
                output = ["blocked": MacWordMemoryFileStore.isBlocked(payload[0], by: snapshot.blockedWords)]
            } else {
                output = [
                    "entries": snapshot.entries.map { word -> [String: Any] in
                        ["input": word.input, "text": word.text, "count": word.count,
                         "lastUsed": word.lastUsed, "manual": word.manual]
                    },
                    "blocked": snapshot.blockedWords,
                    "learning": snapshot.learningEnabled,
                ]
            }
            let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(bytes + Data("\n".utf8))
        } catch {
            let output = (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription], options: [.sortedKeys]))
                ?? Data("{\"error\":\"Memory protocol tool failed\"}".utf8)
            FileHandle.standardError.write(output + Data("\n".utf8))
            exit(2)
        }
    }
}
