import Foundation

actor DebugTraceLogger {
    static let shared = DebugTraceLogger()

    private let logURL: URL
    private let timestampFormatter: ISO8601DateFormatter

    init() {
        let base = RuntimeEnvironment.mlIntegrationRootURL()
        self.logURL = base.appendingPathComponent("vm-debug.log", isDirectory: false)
        self.timestampFormatter = ISO8601DateFormatter()
    }

    func append(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("DebugTraceLogger error: \(error.localizedDescription)")
        }
        print(line, terminator: "")
    }

    func path() -> String {
        logURL.path
    }
}

func traceVM(_ message: String) {
    Task {
        await DebugTraceLogger.shared.append(message)
    }
}
