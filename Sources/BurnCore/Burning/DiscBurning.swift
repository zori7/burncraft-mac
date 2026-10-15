import Foundation

public struct DriveInfo: Sendable, Equatable {
    public let name: String
    public let canWriteBD: Bool
    /// True for `SimulatedBurner`; the UI marks it so it can't be mistaken for a real drive.
    public let isSimulated: Bool

    public init(name: String, canWriteBD: Bool, isSimulated: Bool = false) {
        self.name = name
        self.canWriteBD = canWriteBD
        self.isSimulated = isSimulated
    }
}

public struct MediaStatus: Sendable, Equatable {
    public let isBlank: Bool
    /// DiscRecording's media type string, e.g. "DRDeviceMediaTypeBDR".
    public let discRecordingType: String?
    public let freeBytes: Int64?
    /// Write speeds the drive offers for this disc, in KB/s.
    public let burnSpeedsKBps: [Double]

    public init(isBlank: Bool, discRecordingType: String?, freeBytes: Int64?, burnSpeedsKBps: [Double] = []) {
        self.isBlank = isBlank
        self.discRecordingType = discRecordingType
        self.freeBytes = freeBytes
        self.burnSpeedsKBps = burnSpeedsKBps
    }

    /// "BD-R", "BD-RE", … for display.
    public var typeName: String {
        guard let discRecordingType else { return "unknown disc" }
        return discRecordingType.replacingOccurrences(of: "DRDeviceMediaType", with: "")
            .replacingOccurrences(of: "BDRE", with: "BD-RE")
            .replacingOccurrences(of: "BDR", with: "BD-R")
            .replacingOccurrences(of: "BDROM", with: "BD-ROM")
    }
}

public struct BurnRequest: Sendable, Equatable {
    public let image: URL
    public let speedKBps: Double
    /// The drive's own read-back verify (doubles the burn time).
    public let driveVerify: Bool

    public init(image: URL, speedKBps: Double, driveVerify: Bool) {
        self.image = image
        self.speedKBps = speedKBps
        self.driveVerify = driveVerify
    }
}

public struct BurnUpdate: Sendable {
    public let phase: String
    public let fraction: Double?
}

public enum BurnError: LocalizedError, Sendable {
    case noDrive
    case unreadableImage(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noDrive: "No disc burner found."
        case .unreadableImage(let reason): "Cannot read image: \(reason)"
        case .failed(let reason): "Burn failed: \(reason)"
        }
    }
}

/// A burning engine. `DiscRecordingBurner` is the real one; tests use a fake.
@MainActor
public protocol DiscBurning: AnyObject, Sendable {
    func currentDrive() -> DriveInfo?
    func currentMedia() -> MediaStatus?
    /// Polls until a blank disc is in the drive. Throws `CancellationError` when cancelled.
    func waitForBlankMedia(log: @escaping @Sendable (String) async -> Void) async throws -> MediaStatus
    /// Burns the image. On cancellation the burn is aborted (the disc is likely unusable).
    func burn(_ request: BurnRequest, progress: @escaping @Sendable (BurnUpdate) -> Void) async throws
    @discardableResult func eject() -> Bool
}
