// SimulatedBurnerTests: the hidden "simulated drive" used to try the app without hardware.
//
// Covers:
// - It reports itself as simulated, with a blank BD-R DL inserted.
// - A burn reports progress up to 1, mounts the image with
//   `diskutil image attach --readOnly <image>`, and leaves the disc not blank.
// - Drive verify adds a simulated verifying phase.
// - Burning again without Eject fails; Eject unmounts the image and inserts a new
//   blank disc.
// - Cancelling mid-burn throws and leaves the disc unusable (not blank), like a real drive.
// - Reading the device from `diskutil image attach` output.
// - A full pipeline run with the simulated drive completes, including verify.

@testable import BurnCore
import Foundation
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SimulatedBurnerTests {
    /// Fake runner that answers `diskutil image attach` like the real tool.
    final class DiskutilFake: CommandRunning, @unchecked Sendable {
        let calls = Mutex<[[String]]>([])

        func run(_ executable: String, _ arguments: [String], onOutput: (@Sendable (String) -> Void)?) async throws -> CommandResult {
            calls.withLock { $0.append([executable] + arguments) }
            let output = arguments.first == "image" ? "/dev/disk42\t\t/Volumes/TEST_01\n" : ""
            return CommandResult(exitCode: 0, output: output)
        }
    }

    func makeBurner(_ fake: DiskutilFake) -> SimulatedBurner {
        SimulatedBurner(commandRunner: fake, writeDuration: .milliseconds(50), verifyDuration: .milliseconds(30), tick: .milliseconds(10))
    }

    func makeImage() throws -> (TempDir, URL) {
        let dir = try TempDir()
        let image = try dir.write("TEST_01.iso", Data(repeating: 0, count: 4096))
        return (dir, image)
    }

    @Test func startsAsSimulatedDriveWithBlankDisc() async throws {
        let burner = makeBurner(DiskutilFake())
        #expect(burner.currentDrive()?.isSimulated == true)
        let media = try #require(burner.currentMedia())
        #expect(media.isBlank)
        #expect(media.freeBytes == MediaType.bdr50.capacityBytes)
        #expect(try await burner.waitForBlankMedia { _ in }.isBlank)
    }

    @Test func burnReportsProgressAndMountsImage() async throws {
        let fake = DiskutilFake()
        let burner = makeBurner(fake)
        let (dir, image) = try makeImage()
        let updates = Mutex<[BurnUpdate]>([])

        try await burner.burn(BurnRequest(image: image, speedKBps: 17_984, driveVerify: false)) { u in
            updates.withLock { $0.append(u) }
        }

        let all = updates.withLock { $0 }
        #expect(all.last?.fraction == 1)
        #expect(!all.contains { $0.phase.contains("Verifying") })
        #expect(fake.calls.withLock { $0 } == [["/usr/sbin/diskutil", "image", "attach", "--readOnly", image.path]])
        #expect(burner.mountedDevice == "/dev/disk42")
        #expect(burner.currentMedia()?.isBlank == false)
        _ = dir
    }

    @Test func driveVerifyAddsVerifyingPhase() async throws {
        let burner = makeBurner(DiskutilFake())
        let (dir, image) = try makeImage()
        let phases = Mutex<[String]>([])
        try await burner.burn(BurnRequest(image: image, speedKBps: 1, driveVerify: true)) { u in
            phases.withLock { $0.append(u.phase) }
        }
        #expect(phases.withLock { $0 }.contains { $0.contains("Verifying") })
        _ = dir
    }

    @Test func ejectUnmountsAndInsertsNewBlankDisc() async throws {
        let fake = DiskutilFake()
        let burner = makeBurner(fake)
        let (dir, image) = try makeImage()
        let request = BurnRequest(image: image, speedKBps: 1, driveVerify: false)
        try await burner.burn(request) { _ in }

        await #expect(throws: BurnError.self) { try await burner.burn(request) { _ in } }

        burner.eject()
        #expect(burner.currentMedia()?.isBlank == true)
        #expect(burner.mountedDevice == nil)
        // The unmount runs in the background.
        for _ in 0..<100 where !fake.calls.withLock({ $0.contains(["/usr/sbin/diskutil", "eject", "/dev/disk42"]) }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fake.calls.withLock { $0.contains(["/usr/sbin/diskutil", "eject", "/dev/disk42"]) })
        _ = dir
    }

    @Test func cancelDuringBurnRuinsTheDisc() async throws {
        let fake = DiskutilFake()
        let burner = SimulatedBurner(commandRunner: fake, writeDuration: .seconds(30), tick: .milliseconds(10))
        let (dir, image) = try makeImage()
        let task = Task {
            try await burner.burn(BurnRequest(image: image, speedKBps: 1, driveVerify: false)) { _ in }
        }
        while burner.currentMedia()?.isBlank == true { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(burner.currentMedia()?.isBlank == false)
        #expect(fake.calls.withLock { $0 }.isEmpty) // nothing mounted
        _ = dir
    }

    @Test func parsesDeviceFromAttachOutput() {
        #expect(SimulatedBurner.device(fromAttachOutput: "/dev/disk14\t\t/Volumes/TEST_01\n") == "/dev/disk14")
        #expect(SimulatedBurner.device(fromAttachOutput: "") == nil)
    }

    @Test func fullPipelineRunWithSimulatedDrive() async throws {
        let source = try TempDir()
        try Fixture.makeSourceTree(in: source)
        let output = try TempDir()
        let burner = makeBurner(DiskutilFake())
        let runner = PipelineRunner(
            services: PipelineServices(
                commandRunner: FakeCommandRunner(), burner: burner,
                mountWatcher: FakeMountWatcher(volume: source.url)),
            autoConfirm: true)
        let job = ArchiveJob(sourceFolder: source.url, outputFolder: output.url, volumeName: "TEST_01", verification: .both)

        #expect(await runner.run(job: job) == .succeeded)
        #expect(runner.steps.allSatisfy { $0.state == .done })
        #expect(burner.currentMedia()?.isBlank == false)
    }
}
