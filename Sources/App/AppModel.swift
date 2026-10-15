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
    let burner = DiscRecordingBurner()
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
        didSet { defaults.set(verification.rawValue, forKey: Keys.verification) }
    }
    var cleanMetadata: Bool {
        didSet { defaults.set(cleanMetadata, forKey: Keys.cleanMetadata) }
    }
    var burnSpeed: Int {
        didSet { defaults.set(burnSpeed, forKey: Keys.burnSpeed) }
    }

    private(set) var drive: DriveInfo?
    private(set) var insertedMedia: MediaStatus?
    private(set) var lastJob: ArchiveJob?

    init() {
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

    var canStart: Bool {
        !runner.isRunning && sourceFolder != nil && outputFolder != nil && volumeNameProblem == nil
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

    func start() {
        guard canStart, let job = makeJob() else { return }
        lastJob = job
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
        insertedMedia = burner.currentMedia()
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
