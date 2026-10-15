import Foundation

/// Appends log lines to a dated file in `AppInfo.logDirectory`.
public final class LogFile: Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public static func makeDefault(date: Date = .now) -> LogFile? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = AppInfo.logDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return LogFile(url: directory.appending(path: "\(formatter.string(from: date)).log", directoryHint: .notDirectory))
    }

    public func append(_ line: String) {
        lock.withLock {
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
