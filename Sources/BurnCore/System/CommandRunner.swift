import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let output: String
}

public struct CommandError: LocalizedError, Sendable {
    public let command: String
    public let exitCode: Int32
    public let output: String

    public var errorDescription: String? {
        let tail = output.split(separator: "\n").suffix(5).joined(separator: "\n")
        return "\(command) failed (exit \(exitCode))" + (tail.isEmpty ? "" : ":\n\(tail)")
    }
}

/// Runs external tools (hdiutil, dot_clean, …). A protocol so tests can fake it.
public protocol CommandRunning: Sendable {
    /// Runs the command to completion. Throws `CommandError` on a non-zero exit and
    /// `CancellationError` (after terminating the process) when the task is cancelled.
    func run(_ executable: String, _ arguments: [String], onOutput: (@Sendable (String) -> Void)?) async throws -> CommandResult
}

extension CommandRunning {
    @discardableResult
    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments, onOutput: nil)
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], onOutput: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = OutputCollector(onLine: onOutput)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        let box = ProcessBox(process)
        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate()
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
        collector.flush()

        try Task.checkCancellation()
        let command = ([executable] + arguments).joined(separator: " ")
        guard exitCode == 0 else {
            throw CommandError(command: command, exitCode: exitCode, output: collector.text)
        }
        return CommandResult(exitCode: exitCode, output: collector.text)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// Accumulates process output and emits complete lines.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var all = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    var text: String { lock.withLock { String(decoding: all, as: UTF8.self) } }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            all.append(data)
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        lines.forEach { onLine?($0) }
    }

    func flush() {
        let rest: String? = lock.withLock {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
        if let rest { onLine?(rest) }
    }
}
