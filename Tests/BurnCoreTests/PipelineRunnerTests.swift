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
// - Existing image chosen before the run: Replace rebuilds without asking again;
//   Use Existing skips cleanup, checksums and build and burns the old file as it is.
// - The choice is needed only when the image would be built and the file exists.
// - Cancelling mid-burn aborts the burn, marks it cancelled and skips the rest.
// - A confirmation waits for the user's answer and continues when accepted.
// - A matching disc burns without any confirmation (no final "Burn?" prompt).
// - An inserted disc that doesn't match Media (e.g. BD-R DL 50 with Media set to
//   BD-XL 100) pauses the burn for confirmation: declining stops the run before
//   burning, accepting burns; a matching disc doesn't ask.
// - Only "Verify disc" lacks a step toggle (the verification mode controls it), and
//   with mode None it is skipped even though no step was switched off.

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

    @Test func verifyStepIsControlledOnlyByVerificationMode() async throws {
        let withoutToggle = PipelineRunner.standardSteps().filter { !$0.hasStepToggle }.map(\.id)
        #expect(withoutToggle == [.verify])

        let s = try makeSetup(verification: .none)
        #expect(s.job.skippedSteps.isEmpty)
        await s.runner.run(job: s.job)
        #expect(s.runner.steps.first { $0.id == .verify }?.state == .skipped)
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

    @Test func replacingExistingImageRebuildsWithoutAsking() async throws {
        let s = try makeSetup(autoConfirm: nil) // any confirmation would hang the test
        try Data([0]).write(to: s.job.imageURL)
        var job = s.job
        #expect(job.needsExistingImageChoice)
        job.existingImage = .replace
        job.skippedSteps = [.sizeCheck, .burn, .verify]

        #expect(await s.runner.run(job: job) == .succeeded)
        #expect(try Data(contentsOf: s.job.imageURL) != Data([0]))
        #expect(s.runner.logLines.contains { $0.contains("Deleted the existing TEST_01.iso") })
    }

    @Test func reusingExistingImageSkipsImageInputSteps() async throws {
        // Drive verify: the fake "disc" here is the source folder, which has no manifest
        // when checksums are skipped. (A reused real image carries its own manifest.)
        let s = try makeSetup(verification: .drive)
        let old = Data(repeating: 7, count: 2048)
        try old.write(to: s.job.imageURL)
        var job = s.job
        job.existingImage = .reuse

        #expect(await s.runner.run(job: job) == .succeeded)
        let states = Dictionary(uniqueKeysWithValues: s.runner.steps.map { ($0.id, $0.state) })
        #expect(states[.clean] == .skipped && states[.checksums] == .skipped && states[.buildImage] == .skipped)
        #expect(states[.burn] == .done)
        #expect(s.commands.calls.isEmpty) // no dot_clean, no hdiutil
        #expect(s.burner.requests.first?.image == s.job.imageURL)
        #expect(try Data(contentsOf: s.job.imageURL) == old)
    }

    @Test func existingImageChoiceNeededOnlyWhenBuildingOverAFile() throws {
        let s = try makeSetup()
        var job = s.job
        #expect(!job.needsExistingImageChoice) // no file yet
        try Data([0]).write(to: job.imageURL)
        #expect(job.needsExistingImageChoice)
        job.skippedSteps = [.buildImage]
        #expect(!job.needsExistingImageChoice) // not building: the file is just burned
        job.skippedSteps = []
        job.existingImage = .reuse
        #expect(!job.needsExistingImageChoice) // already decided
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

    @Test func mismatchedDiscAsksBeforeBurning() async throws {
        let declined = try makeSetup(autoConfirm: false)
        var job = declined.job
        job.media = .bdxl100
        job.skippedSteps = [.sizeCheck]
        let outcome = await declined.runner.run(job: job)
        #expect(outcome == .failed(PipelineError.declined("inserted disc doesn't match Media").localizedDescription))
        #expect(declined.burner.requests.isEmpty)

        let accepted = try makeSetup(autoConfirm: true)
        job = accepted.job
        job.media = .bdxl100
        #expect(await accepted.runner.run(job: job) == .succeeded)
        #expect(accepted.burner.requests.count == 1)
        #expect(accepted.runner.logLines.contains { $0.contains("looks like BD-R DL 50 GB, but Media is set to BD-R XL 100 GB") })
    }

    @Test func matchingDiscBurnsWithoutAsking() async throws {
        let s = try makeSetup(autoConfirm: nil) // a confirmation would hang the test
        #expect(await s.runner.run(job: s.job) == .succeeded)
        #expect(s.burner.requests.count == 1)
        #expect(s.runner.logLines.contains { $0.contains("Burning TEST_01.iso") })
    }

    @Test func mediaMismatchDescriptions() {
        let blank50 = MediaStatus(isBlank: true, discRecordingType: "DRDeviceMediaTypeBDR", freeBytes: MediaType.bdr50.capacityBytes)
        #expect(BurnStep.mediaMismatch(inserted: blank50, expected: .bdr50) == nil)
        #expect(BurnStep.mediaMismatch(inserted: blank50, expected: .bdxl100) != nil)
        let blankRE = MediaStatus(isBlank: true, discRecordingType: "DRDeviceMediaTypeBDRE", freeBytes: MediaType.bdr50.capacityBytes)
        #expect(BurnStep.mediaMismatch(inserted: blankRE, expected: .bdr50) == "Inserted disc (BD-RE) is not a BD-R DL 50 GB.")
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
