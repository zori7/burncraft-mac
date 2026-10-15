// ChecksumGeneratorTests: writing checksums.sha256 into the source folder.
//
// Covers:
// - Only regular files are listed, sorted by path; dot-files, .DS_Store and the
//   manifest itself are skipped (same filters as make_archive.sh's `find`).
// - Output is byte-for-byte identical to `shasum -a 256 ./path`, and
//   `shasum -a 256 -c checksums.sha256` passes on it (integration: runs shasum).
// - Paths with spaces, non-ASCII characters, empty files, and files larger than
//   one hash chunk.
// - Regenerating replaces the old manifest instead of hashing it.
// - Byte-based progress reaches the total.
// - An empty folder produces an empty manifest.

@testable import BurnCore
import Foundation
import Testing

@Suite struct ChecksumGeneratorTests {
    @Test func listsExpectedFilesSortedAndSkipsDotFiles() throws {
        let dir = try TempDir()
        try Fixture.makeSourceTree(in: dir)
        let manifest = try ChecksumGenerator().generate(in: dir.url)

        #expect(manifest.lastPathComponent == "checksums.sha256")
        let paths = try String(contentsOf: manifest, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { ChecksumAlgorithm.sha256.parseManifestLine($0)?.relativePath }
        #expect(paths == Fixture.expectedFiles)
    }

    @Test(.tags(.integration)) func matchesShasumByteForByte() throws {
        let dir = try TempDir()
        try Fixture.makeSourceTree(in: dir)
        let manifest = try ChecksumGenerator().generate(in: dir.url)
        let ours = try String(contentsOf: manifest, encoding: .utf8)

        var expected = ""
        for path in Fixture.expectedFiles {
            let result = try shell("/usr/bin/shasum", ["-a", "256", "./\(path)"], in: dir.url)
            #expect(result.status == 0)
            expected += result.output
        }
        #expect(ours == expected)

        let check = try shell("/usr/bin/shasum", ["-a", "256", "-c", "checksums.sha256"], in: dir.url)
        #expect(check.status == 0, "shasum -c output:\n\(check.output)")
    }

    @Test func regeneratingDoesNotListTheManifestItself() throws {
        let dir = try TempDir()
        try dir.write("a.txt", "a")
        try ChecksumGenerator().generate(in: dir.url)
        let manifest = try ChecksumGenerator().generate(in: dir.url)
        let text = try String(contentsOf: manifest, encoding: .utf8)
        #expect(!text.contains("checksums.sha256"))
        #expect(text.split(separator: "\n").count == 1)
    }

    @Test func reportsByteProgressUpToTotal() throws {
        let dir = try TempDir()
        try dir.write("big.bin", Data(repeating: 1, count: FileHasher.chunkSize * 2 + 10))
        try dir.write("small.txt", "x")
        let last = Mutex<HashProgress?>(nil)
        try ChecksumGenerator().generate(in: dir.url) { p in last.withLock { $0 = p } }
        let final = try #require(last.withLock { $0 })
        #expect(final.bytesDone == final.bytesTotal)
        #expect(final.bytesTotal == Int64(FileHasher.chunkSize * 2 + 11))
    }

    @Test func emptyFolderWritesEmptyManifest() throws {
        let dir = try TempDir()
        let manifest = try ChecksumGenerator().generate(in: dir.url)
        #expect(try String(contentsOf: manifest, encoding: .utf8).isEmpty)
    }
}

/// Minimal lock-protected box for collecting values from @Sendable callbacks.
final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}
