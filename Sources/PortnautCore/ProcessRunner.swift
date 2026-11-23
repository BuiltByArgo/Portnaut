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
            // The wait ends on Foundation's exit callback, not on re-checking
            // isRunning. waitUntilExit is not used: it runs the current thread's
            // run loop, which can hang when an async task resumes on another thread.
            enum Event { case exited(Int32), timedOut, graceOver }
            let (events, sink) = AsyncStream.makeStream(of: Event.self)
            process.terminationHandler = { sink.yield(.exited($0.terminationStatus)) }
            var deadlines: [Task<Void, Never>] = []
            defer {
                deadlines.forEach { $0.cancel() }
                sink.finish()
            }
            func send(_ event: Event, at deadline: ContinuousClock.Instant) -> Task<Void, Never> {
                Task {
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    sink.yield(event)
                }
            }
            try process.run()
            let start = Date()
            if let timeout { deadlines.append(send(.timedOut, at: .now + .seconds(timeout))) }
            var timedOut = false
            func tooLong() -> PortnautError {
                try? handle.write(contentsOf: Data("\n[\(ISO8601DateFormatter().string(from: Date()))] stopped by Portnaut after \(Diagnostics.formatted(Date().timeIntervalSince(start))): took too long\n".utf8))
                return PortnautError("\(executable.lastPathComponent) took too long. Open Diagnostics for the log, then retry.")
            }
            for await event in events {
                switch event {
                case .exited(let status):
                    if timedOut { throw tooLong() }
                    // How the program ended, for reports: an installer that quits at once shows here.
                    try? handle.write(contentsOf: Data(Diagnostics.exitLine(status: status, seconds: Date().timeIntervalSince(start)).utf8))
                    guard allowFailure || status == 0 else {
                        throw PortnautError("\(executable.lastPathComponent) exited with code \(status). See \(log.lastPathComponent) in Diagnostics for details.")
                    }
                    return status
                case .timedOut:
                    // Already ended: its .exited follows and counts as a normal exit.
                    guard process.isRunning else { continue }
                    timedOut = true
                    process.terminate()
                    deadlines.append(send(.graceOver, at: .now + .milliseconds(300)))
                case .graceOver:
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw tooLong()
                }
            }
            // Only cancelling this task ends the stream early, and nothing holds it to cancel it.
            preconditionFailure("The exit events of \(executable.lastPathComponent) ended before its exit")
        }.value
    }
}
