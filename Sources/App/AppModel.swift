import AppKit
import BurnCore
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let outputFolder = "outputFolder"
        static let mediaID = "mediaID"
        static let verification = "verification"
        static let cleanMetadata = "cleanMetadata"
        static let burnSpeed = "burnSpeed"
    }

    private let defaults = UserDefaults.standard
    let burner: any DiscBurning
    let runner: PipelineRunner

    var sourceFolder: URL?
    var volumeName = AppInfo.defaultVolumeName()
    var skippedSteps: Set<StepID> = []

    var outputFolder: URL? {
        didSet { defaults.set(outputFolder?.path, forKey: Keys.outputFolder) }
    }
    var media: MediaType {
        didSet {
            defaults.set(media.id, forKey: Keys.mediaID)
            if !media.speedChoices.contains(burnSpeed) { burnSpeed = media.speedChoices.first ?? AppInfo.defaultBurnSpeed }
        }
    }
    var verification: VerificationMode {
        didSet {
            defaults.set(verification.rawValue, forKey: Keys.verification)
            // Checksum verification needs the manifest, so turn its generation back on.
            if verification.usesChecksumVerify, skippedSteps.contains(.checksums) {
                skippedSteps.remove(.checksums)
                showHint("Generate checksums was turned on. \(verification.displayName) needs it.")
            }
        }
    }
    var cleanMetadata: Bool {
        didSet { defaults.set(cleanMetadata, forKey: Keys.cleanMetadata) }
    }
    var burnSpeed: Int {
        didSet { defaults.set(burnSpeed, forKey: Keys.burnSpeed) }
    }

    /// A short message shown briefly when one setting changes another.
    private(set) var hint: String?
    private var hintDismissal: Task<Void, Never>?

    private(set) var drive: DriveInfo?
    private(set) var insertedMedia: MediaStatus?
    private(set) var lastJob: ArchiveJob?

    init() {
        burner = AppInfo.isSimulatedDriveEnabled ? SimulatedBurner() : DiscRecordingBurner()
        runner = PipelineRunner(
            services: PipelineServices(
                commandRunner: ProcessCommandRunner(),
                burner: burner,
                mountWatcher: VolumeMountWatcher()),
            logFile: LogFile.makeDefault())

        outputFolder = defaults.string(forKey: Keys.outputFolder).map { URL(filePath: $0, directoryHint: .isDirectory) }
        media = defaults.string(forKey: Keys.mediaID).flatMap(MediaType.media(id:)) ?? .default
        verification = defaults.string(forKey: Keys.verification).flatMap(VerificationMode.init(rawValue:)) ?? .checksums
        cleanMetadata = defaults.object(forKey: Keys.cleanMetadata) as? Bool ?? true
        burnSpeed = defaults.object(forKey: Keys.burnSpeed) as? Int ?? AppInfo.defaultBurnSpeed
    }

    // MARK: Derived state

    var imageFormat: any ImageFormat { ImageFormats.formats(for: media).first ?? ImageFormats.default }

    var volumeNameProblem: String? { imageFormat.validate(volumeName: volumeName) }

    var speedChoices: [Int] {
        let offered = insertedMedia?.burnSpeedsKBps.map(media.speedFactor(forKBps:)).filter { $0 > 0 } ?? []
        return offered.isEmpty ? media.speedChoices : Array(Set(offered)).sorted()
    }

    /// True while the Burn step is running. Eject stays available otherwise, so a
    /// disc can be swapped while a run waits for a blank one.
    var isBurning: Bool {
        runner.steps.contains { step in
            if step.id == .burn, case .running = step.state { true } else { false }
        }
    }

    var canStart: Bool {
        !runner.isRunning && sourceFolder != nil && outputFolder != nil && volumeNameProblem == nil
    }

    /// Steps with a step toggle. Cleanup's toggle is the persisted `cleanMetadata`
    /// setting; the others are per-run skips.
    func isStepOn(_ id: StepID) -> Bool {
        id == .clean ? cleanMetadata : !skippedSteps.contains(id)
    }

    func setStep(_ id: StepID, on: Bool) {
        if id == .clean {
            cleanMetadata = on
        } else if on {
            skippedSteps.remove(id)
        } else {
            skippedSteps.insert(id)
            if id == .checksums, verification.usesChecksumVerify {
                let previous = verification
                verification = previous.withoutChecksumVerify
                showHint("Verify changed from \(previous.displayName) to \(verification.displayName). Checksum verification needs Generate checksums.")
            }
        }
    }

    func showHint(_ message: String) {
        hint = message
        hintDismissal?.cancel()
        hintDismissal = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { hint = nil }
        }
    }

    func dismissHint() {
        hintDismissal?.cancel()
        hint = nil
    }

    func makeJob() -> ArchiveJob? {
        guard let sourceFolder, let outputFolder else { return nil }
        return ArchiveJob(
            sourceFolder: sourceFolder,
            outputFolder: outputFolder,
            volumeName: volumeName,
            media: media,
            imageFormatID: imageFormat.id,
            verification: verification,
            cleanMetadata: cleanMetadata,
            burnSpeed: burnSpeed,
            skippedSteps: skippedSteps)
    }

    // MARK: Actions

    /// A run waiting for the user to choose what to do with an existing image.
    private(set) var jobAwaitingImageChoice: ArchiveJob?

    func start() {
        guard canStart, let job = makeJob() else { return }
        if job.needsExistingImageChoice {
            jobAwaitingImageChoice = job
            return
        }
        startRun(job)
    }

    /// Answer to the existing-image dialog; nil cancels the run.
    func resolveExistingImage(_ choice: ExistingImageChoice?) {
        guard var job = jobAwaitingImageChoice else { return }
        jobAwaitingImageChoice = nil
        guard let choice else { return }
        job.existingImage = choice
        startRun(job)
    }

    private func startRun(_ job: ArchiveJob) {
        lastJob = job
        if drive?.isSimulated == true {
            runner.appendLog("⚠️ Simulated drive: nothing will be written to a real disc.")
        }
        runner.start(job: job) { [weak self] outcome in
            self?.notify(outcome, title: job.volumeName)
        }
    }

    /// Verifies an already-mounted disc (or any folder) against its own manifest.
    func verify(folder: URL) {
        guard !runner.isRunning else { return }
        let job = ArchiveJob(sourceFolder: folder, outputFolder: folder, volumeName: folder.lastPathComponent)
        runner.start(job: job, steps: [VerifyStep(target: .folder(folder))]) { [weak self] outcome in
            self?.notify(outcome, title: "Verify \(folder.lastPathComponent)")
        }
    }

    func cancel() { runner.cancel() }

    func eject() {
        burner.eject()
        refreshDrive()
    }

    var lastImageURL: URL? {
        guard let url = lastJob?.imageURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func revealImage() {
        if let url = lastImageURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func deleteImage() {
        guard let url = lastImageURL else { return }
        do {
            try FileManager.default.removeItem(at: url)
            runner.appendLog("Deleted \(url.path)")
        } catch {
            runner.appendLog("Could not delete \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: Drive monitoring

    func startDriveMonitoring() {
        requestNotificationPermission()
        Task {
            while !Task.isCancelled {
                refreshDrive()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshDrive() {
        drive = burner.currentDrive()
        let previous = insertedMedia
        insertedMedia = burner.currentMedia()
        if let inserted = insertedMedia, inserted != previous {
            selectMediaMatching(inserted)
        }
    }

    /// Sets the Media picker from a newly inserted blank disc. Runs only when the disc
    /// changes, so a manual choice afterwards is kept.
    private func selectMediaMatching(_ inserted: MediaStatus) {
        guard !runner.isRunning, let detected = MediaType.matching(inserted), detected != media else { return }
        media = detected
        showHint("Media set to \(detected.displayName) to match the inserted disc.")
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        guard AppInfo.isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ outcome: PipelineRunner.Outcome, title: String) {
        guard AppInfo.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = AppInfo.name
        switch outcome {
        case .succeeded: content.body = "\(title) finished."
        case .failed(let message): content.body = "\(title) failed: \(message)"
        case .cancelled: content.body = "\(title) was cancelled."
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
