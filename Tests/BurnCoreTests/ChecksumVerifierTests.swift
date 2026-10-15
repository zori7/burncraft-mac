// ChecksumVerifierTests: re-checking files against checksums.sha256 (the app's
// equivalent of `shasum -a 256 -c`).
//
// Covers:
// - Every file verifies on an untouched tree.
// - A modified file is reported as mismatched.
// - A deleted file is reported as missing.
// - Unparseable manifest lines are reported with line numbers, without stopping
//   the check, and make the result a failure.
// - A missing manifest throws.
// - Manifest line parsing: "./" prefix, shasum's "*" binary marker, uppercase
//   digests, and rejection of malformed lines.

@testable import BurnCore
import Foundation
import Testing

@Suite struct ChecksumVerifierTests {
    private func makeVerifiedTree() throws -> TempDir {
        let dir = try TempDir()
        try Fixture.makeSourceTree(in: dir)
        try ChecksumGenerator().generate(in: dir.url)
        return dir
    }

    @Test func allFilesVerify() throws {
        let dir = try makeVerifiedTree()
        let report = try ChecksumVerifier().verify(root: dir.url)
        #expect(report.isSuccess)
        #expect(report.verified.count == Fixture.expectedFiles.count)
    }

    @Test func corruptedFileIsMismatched() throws {
        let dir = try makeVerifiedTree()
        try dir.write("readme.txt", "tampered\n")
        let report = try ChecksumVerifier().verify(root: dir.url)
        #expect(!report.isSuccess)
        #expect(report.mismatched == ["readme.txt"])
    }

    @Test func deletedFileIsMissing() throws {
        let dir = try makeVerifiedTree()
        try FileManager.default.removeItem(at: dir.url.appending(path: "Photos 2024/IMG 0001.jpg"))
        let report = try ChecksumVerifier().verify(root: dir.url)
        #expect(report.missing == ["Photos 2024/IMG 0001.jpg"])
        #expect(report.verified.count == Fixture.expectedFiles.count - 1)
    }

    @Test func malformedLinesAreReportedNotFatal() throws {
        let dir = try makeVerifiedTree()
        let manifest = dir.url.appending(path: "checksums.sha256")
        var text = try String(contentsOf: manifest, encoding: .utf8)
        text += "not a checksum line\n" + String(repeating: "z", count: 64) + "  ./x\n"
        try Data(text.utf8).write(to: manifest)

        let report = try ChecksumVerifier().verify(root: dir.url)
        let count = Fixture.expectedFiles.count
        #expect(report.malformedLines == [count + 1, count + 2])
        #expect(report.verified.count == count)
        #expect(!report.isSuccess)
    }

    @Test func missingManifestThrows() throws {
        let dir = try TempDir()
        #expect(throws: VerificationError.self) { try ChecksumVerifier().verify(root: dir.url) }
    }

    @Test func parsesShasumLineVariants() {
        let digest = String(repeating: "a", count: 64)
        let algorithm = ChecksumAlgorithm.sha256
        #expect(algorithm.parseManifestLine("\(digest)  ./dir/file name.txt")?.relativePath == "dir/file name.txt")
        #expect(algorithm.parseManifestLine("\(digest) *./bin.dat")?.relativePath == nil) // single space + * isn't shasum's format
        #expect(algorithm.parseManifestLine("\(digest)  *bin.dat")?.relativePath == "bin.dat")
        #expect(algorithm.parseManifestLine("\(digest.uppercased())  plain.txt")?.digest == digest)
        #expect(algorithm.parseManifestLine("abc  file") == nil)
    }
}
