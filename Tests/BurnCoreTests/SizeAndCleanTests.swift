// SizeAndCleanTests: the "Check size" and "Clean Apple metadata" steps.
//
// SizeCheckTests covers:
// - Allocated size (like `du -sk`) counts every file, including nested ones.
// - GiB math matches make_archive.sh (KB / 1048576); BD-R DL limit is 46.0 GiB.
// - Over/under-limit decision for every media type, at the exact boundary.
// - The inserted blank disc's free space is used as the limit when present,
//   otherwise the selected media type's limit.
//
// CleanStepTests covers:
// - .DS_Store files are removed recursively; other dot-files are left alone.
// - `dot_clean -m <source>` runs only when cleanup is enabled; when disabled the
//   step is skipped and the folder is untouched (fake command runner).

@testable import BurnCore
import Foundation
import Testing

@Suite struct SizeCheckTests {
    @Test func allocatedSizeCoversAllFiles() throws {
        let dir = try TempDir()
        try dir.write("a.bin", Data(repeating: 1, count: 100_000))
        try dir.write("sub/b.bin", Data(repeating: 2, count: 50_000))
        let size = try FileTree.allocatedSize(of: dir.url)
        #expect(size >= 150_000)
        #expect(size < 150_000 + 64 * 1024) // allocation rounding only
    }

    @Test func gibMathMatchesScript() {
        // make_archive.sh: SIZE_GIB = KB / 1048576
        let kb: Int64 = 48_234_496 // 46.0 GiB in KB
        #expect(ByteFormat.gib(kb * 1024) == "46.00 GiB")
        #expect(MediaType.bdr50.recommendedLimitBytes == kb * 1024)
    }

    @Test(arguments: MediaType.all)
    func limitDecision(media: MediaType) {
        #expect(!SizeCheckStep.exceeds(size: media.recommendedLimitBytes, limit: media.recommendedLimitBytes))
        #expect(SizeCheckStep.exceeds(size: media.recommendedLimitBytes + 1, limit: media.recommendedLimitBytes))
    }

    @Test @MainActor func usesInsertedBlankDiscWhenPresent() throws {
        let burner = FakeBurner()
        let job = ArchiveJob(sourceFolder: URL(filePath: "/tmp"), outputFolder: URL(filePath: "/tmp"), volumeName: "V")
        burner.media = MediaStatus(isBlank: true, discRecordingType: nil, freeBytes: 1234)
        #expect(SizeCheckStep.limit(for: job, burner: burner).bytes == 1234)
        burner.media = nil
        #expect(SizeCheckStep.limit(for: job, burner: burner).bytes == job.media.recommendedLimitBytes)
    }
}

@Suite struct CleanStepTests {
    @Test func removesDSStoreRecursively() throws {
        let dir = try TempDir()
        try Fixture.makeSourceTree(in: dir)
        let removed = try CleanStep.removeDSStoreFiles(in: dir.url)
        #expect(removed == 2)
        #expect(FileTree.files(named: ".DS_Store", in: dir.url).isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.url.appending(path: ".hidden").path))
    }

    @Test @MainActor func runsDotCleanWhenEnabledAndNothingWhenDisabled() async throws {
        let dir = try TempDir()
        try Fixture.makeSourceTree(in: dir)
        let commands = FakeCommandRunner()
        let runner = PipelineRunner(
            services: PipelineServices(commandRunner: commands, burner: FakeBurner(), mountWatcher: FakeMountWatcher(volume: nil)),
            autoConfirm: true)

        var job = ArchiveJob(sourceFolder: dir.url, outputFolder: dir.url, volumeName: "V", cleanMetadata: false)
        await runner.run(job: job, steps: [CleanStep()])
        #expect(commands.calls.isEmpty)
        #expect(FileTree.files(named: ".DS_Store", in: dir.url).count == 2)
        #expect(runner.steps.first?.state == .skipped)

        job.cleanMetadata = true
        await runner.run(job: job, steps: [CleanStep()])
        #expect(commands.calls == [["/usr/sbin/dot_clean", "-m", dir.url.path]])
        #expect(FileTree.files(named: ".DS_Store", in: dir.url).isEmpty)
    }
}
