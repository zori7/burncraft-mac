// PipelineRunnerTests: running the steps in order, with fake burner, command
// runner and mount watcher (no drive or hdiutil needed).
//
// Covers:
// - A full run completes all six steps in order and calls dot_clean and hdiutil,
//   then burns the built image at 4x (BD speed in KB/s).
// - Each verification mode sets the drive-verify flag and runs or skips the
//   checksum verify step accordingly.
// - Steps the user switched off are skipped and don't run.
// - A failing step (image larger than the disc) stops the run; later steps are skipped.
// - A checksum mismatch on the "disc" fails the verify step and logs the file.
// - Declining to overwrite an existing image stops the run and keeps the file.
// - Cancelling mid-burn aborts the burn, marks it cancelled and skips the rest.
// - A confirmation waits for the user's answer and continues when accepted.

@testable import BurnCore
import Foundation
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PipelineRunnerTests {
    struct Setup {
        let source: TempDir
        let output: TempDir
        let commands: FakeCommandRunner
        let burner: FakeBurner
        let runner: PipelineRunner
        let job: ArchiveJob
    }

    /// The fake "disc" mounts as the source folder itself, which holds the manifest.
    /// `autoConfirm: nil` makes confirmations wait for `answerConfirmation`.
    func makeSetup(verification: VerificationMode = .checksums, autoConfirm: Bool? = true, mounts: Bool = true) throws -> Setup {
        let source = try TempDir()
        try Fixture.makeSourceTree(in: source)
        let output = try TempDir()
        let commands = FakeCommandRunner()
        let burner = FakeBurner()
        let runner = PipelineRunner(
            services: PipelineServices(
                commandRunner: commands, burner: burner,
                mountWatcher: FakeMountWatcher(volume: mounts ? source.url : nil)),
            autoConfirm: autoConfirm)
        let job = ArchiveJob(sourceFolder: source.url, outputFolder: output.url, volumeName: "TEST_01", verification: verification)
        return Setup(source: source, output: output, commands: commands, burner: burner, runner: runner, job: job)
    }

    @Test func fullRunCompletesAllStepsInOrder() async throws {
        let s = try makeSetup()
        let outcome = await s.runner.run(job: s.job)

        #expect(outcome == .succeeded)
        #expect(s.runner.steps.map(\.id) == [.sizeCheck, .clean, .checksums, .buildImage, .burn, .verify])
        #expect(s.runner.steps.allSatisfy { $0.state == .done })
        #expect(s.commands.calls.map { $0[0] } == ["/usr/sbin/dot_clean", "/usr/bin/hdiutil"])
        #expect(s.burner.requests.first?.image == s.job.imageURL)
        #expect(s.burner.requests.first?.speedKBps == MediaType.bdr50.speedKBps(forFactor: 4))
        #expect(FileManager.default.fileExists(atPath: s.source.url.appending(path: "checksums.sha256").path))
    }

    @Test(arguments: VerificationMode.allCases)
    func verificationModeControlsDriveVerifyAndChecksumStep(mode: VerificationMode) async throws {
        let s = try makeSetup(verification: mode)
        let outcome = await s.runner.run(job: s.job)

        #expect(outcome == .succeeded)
        #expect(s.burner.requests.first?.driveVerify == mode.usesDriveVerify)
        let verify = try #require(s.runner.steps.first { $0.id == .verify })
        #expect(verify.state == (mode.usesChecksumVerify ? .done : .skipped))
    }

    @Test func userSkippedStepsDoNotRun() async throws {
        let s = try makeSetup()
        var job = s.job
        job.skippedSteps = [.clean, .burn, .verify]
        let outcome = await s.runner.run(job: job)
        #expect(outcome == .succeeded)
        #expect(s.burner.requests.isEmpty)
        #expect(!s.commands.calls.contains { $0[0] == "/usr/sbin/dot_clean" })
        let states = Dictionary(uniqueKeysWithValues: s.runner.steps.map { ($0.id, $0.state) })
        #expect(states[.clean] == .skipped && states[.burn] == .skipped && states[.verify] == .skipped)
        #expect(states[.buildImage] == .done)
    }

    @Test func failureStopsLaterSteps() async throws {
        let s = try makeSetup(mounts: false)
        s.burner.media = MediaStatus(isBlank: true, discRecordingType: nil, freeBytes: 2048) // image won't fit
        let outcome = await s.runner.run(job: s.job)

        guard case .failed = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        let states = Dictionary(uniqueKeysWithValues: s.runner.steps.map { ($0.id, $0.state) })
        if case .failed = states[.burn] {} else { Issue.record("burn should fail: \(String(describing: states[.burn]))") }
        #expect(states[.verify] == .skipped)
        #expect(s.burner.requests.isEmpty)
    }

    @Test func checksumFailureFailsVerifyStep() async throws {
        let s = try makeSetup()
        // Corrupt the "disc" after the manifest is written, before verify: use a custom step order.
        let corrupt = ClosureStep(id: StepID(rawValue: "corrupt")) { _ in
            try Data("tampered".utf8).write(to: s.source.url.appending(path: "readme.txt"))
        }
        let outcome = await s.runner.run(job: s.job, steps: [ChecksumStep(), corrupt, VerifyStep()])
        guard case .failed(let message) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(message.contains("1 mismatched"))
        #expect(s.runner.logLines.contains { $0.contains("MISMATCH readme.txt") })
    }

    @Test func decliningOverwriteStopsTheRun() async throws {
        let s = try makeSetup(autoConfirm: false)
        try Data([0]).write(to: s.job.imageURL)
        var job = s.job
        job.skippedSteps = [.sizeCheck]
        let outcome = await s.runner.run(job: job)

        #expect(outcome == .failed(PipelineError.declined("existing image kept").localizedDescription))
        #expect(s.burner.requests.isEmpty)
        #expect(try Data(contentsOf: s.job.imageURL) == Data([0]))
    }

    @Test func cancelDuringBurnAbortsAndSkipsRest() async throws {
        let s = try makeSetup()
        s.burner.hangUntilCancelled = true

        let finished = AsyncStream<PipelineRunner.Outcome>.makeStream()
        s.runner.start(job: s.job) { finished.continuation.yield($0) }
        while !s.burner.burnStarted { try await Task.sleep(for: .milliseconds(10)) }
        s.runner.cancel()

        var iterator = finished.stream.makeAsyncIterator()
        let outcome = await iterator.next()
        #expect(outcome == .cancelled)
        #expect(s.burner.aborted)
        let states = Dictionary(uniqueKeysWithValues: s.runner.steps.map { ($0.id, $0.state) })
        #expect(states[.burn] == .cancelled)
        #expect(states[.verify] == .skipped)
        #expect(!s.runner.isRunning)
    }

    @Test func pendingConfirmationIsAnsweredByUser() async throws {
        let s = try makeSetup(autoConfirm: nil)
        let ask = ClosureStep(id: StepID(rawValue: "ask")) { context in
            let ok = await context.confirm(ConfirmationRequest(title: "Q", message: "M", confirmLabel: "Yes"))
            if !ok { throw PipelineError.declined("no") }
        }
        let finished = AsyncStream<PipelineRunner.Outcome>.makeStream()
        s.runner.start(job: s.job, steps: [ask]) { finished.continuation.yield($0) }
        while s.runner.pendingConfirmation == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(s.runner.pendingConfirmation?.title == "Q")
        s.runner.answerConfirmation(true)

        var iterator = finished.stream.makeAsyncIterator()
        #expect(await iterator.next() == .succeeded)
        #expect(s.runner.pendingConfirmation == nil)
    }
}

/// A step defined inline, for exercising the runner.
struct ClosureStep: PipelineStep {
    let id: StepID
    var title: String { id.rawValue }
    let body: @Sendable (PipelineContext) async throws -> Void

    func run(_ context: PipelineContext) async throws { try await body(context) }
}
