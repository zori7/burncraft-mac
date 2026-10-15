// IntegrationTests: end-to-end image check with real system tools (tag: integration).
//
// Covers:
// - Building a real UDF 2.50 ISO with hdiutil from a fixture folder; the size is
//   a whole number of 2048-byte blocks.
// - Mounting it read-only (diskutil image attach) with the expected volume name.
// - The app's verifier and `shasum -a 256 -c` both pass on the mounted image,
//   the same path a burned disc takes, minus the drive.
//
// Not covered here: burning to a real disc (needs hardware; tested manually).

@testable import BurnCore
import Foundation
import Testing

/// Builds a real UDF image with hdiutil, mounts it read-only and verifies it,
/// the same path a burned disc takes minus the drive.
@Suite(.tags(.integration), .serialized)
struct ImageIntegrationTests {
    @Test func builtImageMountsAndVerifies() async throws {
        let source = try TempDir()
        try Fixture.makeSourceTree(in: source)
        try CleanStep.removeDSStoreFiles(in: source.url)
        try ChecksumGenerator().generate(in: source.url)

        let out = try TempDir()
        let volumeName = "BCTEST_\(Int.random(in: 1000...9999))"
        let iso = out.url.appending(path: "\(volumeName).iso")
        try await UDFImageFormat.udf250.makeImage(
            source: source.url, volumeName: volumeName, output: iso, runner: ProcessCommandRunner()) { _ in }
        let size = try #require(try FileManager.default.attributesOfItem(atPath: iso.path)[.size] as? NSNumber)
        #expect(size.int64Value % 2048 == 0)

        let mountPoint = try out.subdirectory("mnt")
        let attach = try shell("/usr/sbin/diskutil", [
            "image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mountPoint.path, iso.path,
        ])
        try #require(attach.status == 0, "attach failed: \(attach.output)")
        defer { _ = try? shell("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path]) }

        let name = try mountPoint.resourceValues(forKeys: [.volumeNameKey]).volumeName
        #expect(name == volumeName)

        let report = try ChecksumVerifier().verify(root: mountPoint)
        #expect(report.isSuccess, "\(report.summary)")
        #expect(report.verified.count == Fixture.expectedFiles.count)

        let shasum = try shell("/usr/bin/shasum", ["-a", "256", "-c", "checksums.sha256"], in: mountPoint)
        #expect(shasum.status == 0, "\(shasum.output)")
    }
}
