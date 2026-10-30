import Foundation

public enum ProcessRunner {
    /// Output goes to a file, not an undrained pipe. All commands use argv, never a shell.
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil, directory: URL? = nil, log: URL, timeout: TimeInterval? = 180, allowFailure: Bool = false) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else { throw PortnautError("Could not open \(log.lastPathComponent) for diagnostics.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            let line = "\n[\(ISO8601DateFormatter().string(from: Date()))] \(executable.lastPathComponent) \(arguments.joined(separator: " "))\n"
            try handle.write(contentsOf: Data(line.utf8))
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            process.standardOutput = handle
            process.standardError = handle
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let start = Date()
            while process.isRunning {
                if let timeout, Date().timeIntervalSince(start) > timeout {
                    process.terminate()
                    try? await Task.sleep(for: .milliseconds(300))
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw PortnautError("\(executable.lastPathComponent) took too long. Open Diagnostics for the log, then retry.")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // isRunning becomes false after Foundation records the exit status.
            // waitUntilExit uses a thread-local run loop and can hang when an
            // async task resumes on a different thread from process.run().
            guard allowFailure || process.terminationStatus == 0 else {
                throw PortnautError("\(executable.lastPathComponent) exited with code \(process.terminationStatus). See \(log.lastPathComponent) in Diagnostics for details.")
            }
            return process.terminationStatus
        }.value
    }
}
