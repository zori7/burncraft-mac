import Foundation

/// A pretend drive for trying the app without hardware (hidden developer setting,
/// see `AppInfo.simulatedDriveDefaultsKey`).
///
/// It starts with a blank BD-R DL, "burns" by reporting progress for a fixed time,
/// then mounts the image read-only so the Verify step finds it like a burned disc.
/// After a burn the disc is no longer blank; Eject unmounts it and inserts a new blank disc.
@MainActor
public final class SimulatedBurner: DiscBurning {
    static let diskutil = "/usr/sbin/diskutil"
    static let media = MediaType.bdr50

    private let commandRunner: any CommandRunning
    private let writeDuration: Duration
    private let verifyDuration: Duration
    private let tick: Duration

    private(set) var isBlank = true
    /// `/dev/diskN` of the mounted image, used by Eject.
    private(set) var mountedDevice: String?

    public init(
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        writeDuration: Duration = .seconds(10),
        verifyDuration: Duration = .seconds(5),
        tick: Duration = .milliseconds(100)
    ) {
        self.commandRunner = commandRunner
        self.writeDuration = writeDuration
        self.verifyDuration = verifyDuration
        self.tick = tick
    }

    public func currentDrive() -> DriveInfo? {
        DriveInfo(name: "Simulated BD Burner", canWriteBD: true, isSimulated: true)
    }

    public func currentMedia() -> MediaStatus? {
        MediaStatus(
            isBlank: isBlank,
            discRecordingType: Self.media.discRecordingTypes.first,
            freeBytes: isBlank ? Self.media.capacityBytes : 0,
            burnSpeedsKBps: Self.media.speedChoices.map(Self.media.speedKBps(forFactor:)))
    }

    public func waitForBlankMedia(log: @escaping @Sendable (String) async -> Void) async throws -> MediaStatus {
        var asked = false
        while true {
            try Task.checkCancellation()
            if isBlank, let media = currentMedia() { return media }
            if !asked {
                await log("The simulated disc is already burned. Press Eject to insert a new blank disc.")
                asked = true
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    public func burn(_ request: BurnRequest, progress: @escaping @Sendable (BurnUpdate) -> Void) async throws {
        guard isBlank else { throw BurnError.failed("the simulated disc is not blank") }
        guard FileManager.default.fileExists(atPath: request.image.path) else {
            throw BurnError.unreadableImage("no file at \(request.image.path)")
        }

        do {
            progress(BurnUpdate(phase: "Preparing (simulated)", fraction: nil))
            try await Task.sleep(for: tick)
            // Past this point a real disc would be written to.
            isBlank = false
            try await runPhase("Writing (simulated)", duration: writeDuration, progress: progress)
            if request.driveVerify {
                try await runPhase("Verifying (drive, simulated)", duration: verifyDuration, progress: progress)
            }
        } catch {
            progress(BurnUpdate(phase: "Aborted", fraction: nil))
            throw error
        }

        progress(BurnUpdate(phase: "Mounting image as the burned disc", fraction: nil))
        let result = try await commandRunner.run(Self.diskutil, ["image", "attach", "--readOnly", request.image.path])
        mountedDevice = Self.device(fromAttachOutput: result.output)
        progress(BurnUpdate(phase: "Done", fraction: 1))
    }

    @discardableResult
    public func eject() -> Bool {
        if let device = mountedDevice {
            let runner = commandRunner
            Task { try? await runner.run(Self.diskutil, ["eject", device]) }
        }
        mountedDevice = nil
        isBlank = true
        return true
    }

    private func runPhase(_ phase: String, duration: Duration, progress: @Sendable (BurnUpdate) -> Void) async throws {
        let steps = max(1, Int(duration / tick))
        for step in 1...steps {
            try await Task.sleep(for: tick)
            progress(BurnUpdate(phase: phase, fraction: Double(step) / Double(steps)))
        }
    }

    /// First "/dev/diskN" in `diskutil image attach` output ("/dev/disk14\t\t/Volumes/NAME").
    static func device(fromAttachOutput output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("/dev/disk") }.map(String.init)
    }
}
