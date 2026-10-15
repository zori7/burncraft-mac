// TestSupport: shared helpers, not tests.
//
// - TempDir: self-deleting temporary folder with file-writing helpers.
// - Fixture: a source tree with nested folders, spaces, non-ASCII names, an empty
//   file, a multi-chunk file, and files that must be excluded (.DS_Store, dot-files).
// - shell(): runs a real command, for cross-checking against system tools.
// - Fakes: FakeCommandRunner, FakeBurner, FakeMountWatcher.

@testable import BurnCore
import Foundation
import Testing

extension Tag {
    /// Tests that run real system tools (hdiutil/diskutil/shasum).
    @Tag static var integration: Self
}

/// A temporary directory removed when the value is deallocated.
final class TempDir: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "BurnCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relativePath: String, _ data: Data) throws -> URL {
        let file = url.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    @discardableResult
    func write(_ relativePath: String, _ text: String) throws -> URL {
        try write(relativePath, Data(text.utf8))
    }

    func subdirectory(_ name: String) throws -> URL {
        let dir = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum Fixture {
    /// Nested dirs, spaces, unicode, an empty file, a file bigger than one hash chunk,
    /// plus files that must be excluded (.DS_Store, dot-files).
    static func makeSourceTree(in dir: TempDir) throws {
        try dir.write("readme.txt", "hello archive\n")
        try dir.write("Photos 2024/IMG 0001.jpg", Data(repeating: 0xAB, count: 4096))
        try dir.write("Photos 2024/Café Ü/naïve résumé.txt", "unicode path\n")
        try dir.write("empty.bin", Data())
        try dir.write("deep/a/b/c/data.bin", randomData(count: FileHasher.chunkSize + 12_345))
        try dir.write(".DS_Store", "junk")
        try dir.write("Photos 2024/.DS_Store", "junk")
        try dir.write(".hidden", "hidden file")
    }

    static let expectedFiles = [
        "Photos 2024/Café Ü/naïve résumé.txt",
        "Photos 2024/IMG 0001.jpg",
        "deep/a/b/c/data.bin",
        "empty.bin",
        "readme.txt",
    ]

    static func randomData(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }
}

/// Runs a real command and returns its output (for cross-checking with system tools).
@discardableResult
func shell(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

// MARK: - Fakes

final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    let failing: Set<String>

    init(failing: Set<String> = []) { self.failing = failing }

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ executable: String, _ arguments: [String], onOutput: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        lock.withLock { _calls.append([executable] + arguments) }
        if failing.contains(executable) {
            throw CommandError(command: executable, exitCode: 1, output: "fake failure")
        }
        // Pretend to be hdiutil makehybrid: write a small image at the -o path.
        if executable.hasSuffix("hdiutil"), let index = arguments.firstIndex(of: "-o") {
            try Data(repeating: 0, count: 4 * 2048).write(to: URL(filePath: arguments[index + 1]))
        }
        return CommandResult(exitCode: 0, output: "")
    }
}

@MainActor
final class FakeBurner: DiscBurning {
    var media: MediaStatus? = MediaStatus(isBlank: true, discRecordingType: "DRDeviceMediaTypeBDR", freeBytes: MediaType.bdr50.capacityBytes)
    var requests: [BurnRequest] = []
    var hangUntilCancelled = false
    var aborted = false
    var burnStarted = false

    func currentDrive() -> DriveInfo? { DriveInfo(name: "Fake BD Burner", canWriteBD: true) }
    func currentMedia() -> MediaStatus? { media }

    func waitForBlankMedia(log: @escaping @Sendable (String) async -> Void) async throws -> MediaStatus {
        guard let media, media.isBlank else { throw BurnError.failed("no blank media in fake") }
        return media
    }

    func burn(_ request: BurnRequest, progress: @escaping @Sendable (BurnUpdate) -> Void) async throws {
        requests.append(request)
        burnStarted = true
        progress(BurnUpdate(phase: "Writing", fraction: 0.5))
        if hangUntilCancelled {
            do {
                while true { try await Task.sleep(for: .milliseconds(20)) }
            } catch {
                aborted = true
                throw error
            }
        }
    }

    func eject() -> Bool { true }
}

struct FakeMountWatcher: MountWatching {
    let volume: URL?

    func waitForVolume(named name: String, timeout: Duration) async throws -> URL {
        guard let volume else { throw MountError.timedOut(volumeName: name) }
        return volume
    }
}
