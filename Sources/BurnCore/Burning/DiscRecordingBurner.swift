import DiscRecording
import Foundation

/// Burns images with Apple's DiscRecording framework (the engine behind `drutil`).
/// Status is polled rather than observed; DiscRecording notifications need a run loop
/// and polling every half second is plenty for a burn that takes tens of minutes.
@MainActor
public final class DiscRecordingBurner: DiscBurning {
    private static let blockSize: Int64 = 2048
    private static let pollInterval: Duration = .milliseconds(500)

    public init() {}

    private var device: DRDevice? {
        let devices = (DRDevice.devices() as? [DRDevice]) ?? []
        return devices.first { Self.canWriteBD($0) } ?? devices.first
    }

    private static func canWriteBD(_ device: DRDevice) -> Bool {
        let capabilities = device.info()?[DRDeviceWriteCapabilitiesKey] as? [AnyHashable: Any]
        return (capabilities?[DRDeviceCanWriteBDKey] as? Bool) ?? false
    }

    public func currentDrive() -> DriveInfo? {
        guard let device else { return nil }
        return DriveInfo(name: device.displayName() ?? "Disc burner", canWriteBD: Self.canWriteBD(device))
    }

    public func currentMedia() -> MediaStatus? {
        guard let status = device?.status(),
              status[DRDeviceMediaStateKey] as? String == DRDeviceMediaStateMediaPresent,
              let info = status[DRDeviceMediaInfoKey] as? [AnyHashable: Any] else { return nil }
        let blocksFree = (info[DRDeviceMediaBlocksFreeKey] as? NSNumber)?.int64Value
        let speeds = (status[DRDeviceBurnSpeedsKey] as? [NSNumber])?.map(\.doubleValue) ?? []
        return MediaStatus(
            isBlank: (info[DRDeviceMediaIsBlankKey] as? Bool) ?? false,
            discRecordingType: info[DRDeviceMediaTypeKey] as? String,
            freeBytes: blocksFree.map { $0 * Self.blockSize },
            burnSpeedsKBps: speeds)
    }

    public func waitForBlankMedia(log: @escaping @Sendable (String) async -> Void) async throws -> MediaStatus {
        var lastMessage: String?
        while true {
            try Task.checkCancellation()
            let message: String
            if let drive = currentDrive() {
                if let media = currentMedia() {
                    if media.isBlank { return media }
                    message = "The disc in \(drive.name) is not blank. Insert a blank disc."
                } else {
                    message = "Insert a blank disc into \(drive.name)."
                }
            } else {
                message = "Connect a disc burner."
            }
            if message != lastMessage {
                await log(message)
                lastMessage = message
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    public func burn(_ request: BurnRequest, progress: @escaping @Sendable (BurnUpdate) -> Void) async throws {
        guard let device else { throw BurnError.noDrive }
        let producer = try ImageTrackProducer(url: request.image)

        guard let track = DRTrack(producer: producer) else { throw BurnError.failed("could not create track") }
        track.setProperties([
            DRTrackLengthKey: DRMSF(frames: UInt32(producer.blockCount)) as Any,
            DRBlockSizeKey: kDRBlockSizeMode1Data,
            DRBlockTypeKey: kDRBlockTypeMode1Data,
            DRDataFormKey: kDRDataFormMode1Data,
            DRSessionFormatKey: kDRSessionFormatMode1Data,
            DRTrackModeKey: kDRTrackMode1Data,
            DRVerificationTypeKey: request.driveVerify ? DRVerificationTypeProduceAgain : DRVerificationTypeNone,
        ])

        guard let burn = DRBurn(for: device) else { throw BurnError.failed("could not open the drive") }
        burn.setRequestedBurnSpeed(Float(request.speedKBps))
        burn.setVerifyDisc(request.driveVerify)
        burn.setAppendable(false)
        burn.setCompletionAction(DRBurnCompletionActionMount)
        burn.writeLayout(track)

        // DRBurn isn't Sendable; abort() is safe to call from the cancellation handler.
        let handle = BurnHandle(burn)
        try await withTaskCancellationHandler { @MainActor in
            let burn = handle.burn
            while true {
                let status = burn.status() ?? [:]
                let state = status[DRStatusStateKey] as? String
                if state == DRStatusStateDone {
                    progress(BurnUpdate(phase: "Done", fraction: 1))
                    return
                }
                if state == DRStatusStateFailed {
                    throw BurnError.failed(Self.errorDescription(from: status))
                }
                let percent = (status[DRStatusPercentCompleteKey] as? NSNumber)?.doubleValue ?? -1
                progress(BurnUpdate(phase: Self.phaseName(state), fraction: percent >= 0 ? percent : nil))
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    burn.abort()
                    throw error
                }
            }
        } onCancel: {
            handle.burn.abort()
        }
        withExtendedLifetime(producer) {}
    }

    @discardableResult
    public func eject() -> Bool { device?.ejectMedia() ?? false }

    private static func phaseName(_ state: String?) -> String {
        switch state {
        case DRStatusStatePreparing: "Preparing"
        case DRStatusStateVerifying: "Verifying (drive)"
        case DRStatusStateFinishing, DRStatusStateSessionClose, DRStatusStateTrackClose: "Finishing"
        case DRStatusStateSessionOpen, DRStatusStateTrackOpen: "Starting"
        case DRStatusStateTrackWrite: "Writing"
        default: "Burning"
        }
    }

    private static func errorDescription(from status: [AnyHashable: Any]) -> String {
        let error = status[DRErrorStatusKey] as? [AnyHashable: Any]
        let message = error?[DRErrorStatusErrorStringKey] as? String ?? "unknown error"
        if let code = error?[DRErrorStatusErrorKey] as? NSNumber {
            return "\(message) (code \(code))"
        }
        return message
    }
}

private final class BurnHandle: @unchecked Sendable {
    let burn: DRBurn
    init(_ burn: DRBurn) { self.burn = burn }
}

/// Streams an image file to DiscRecording as a single Mode 1 (2048-byte block) data track.
final class ImageTrackProducer: NSObject, DRTrackDataProduction, @unchecked Sendable {
    let url: URL
    let byteCount: Int64
    let blockCount: Int64
    private var fd: Int32 = -1
    private var offset: Int64 = 0

    init(url: URL) throws {
        self.url = url
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw BurnError.unreadableImage(error.localizedDescription)
        }
        byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else { throw BurnError.unreadableImage("image is empty") }
        blockCount = (byteCount + 2047) / 2048
        guard blockCount <= Int64(UInt32.max) else { throw BurnError.unreadableImage("image is too large") }
    }

    deinit { closeFile() }

    private func openFile() -> Bool {
        closeFile()
        fd = open(url.path, O_RDONLY)
        offset = 0
        return fd >= 0
    }

    private func closeFile() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    func estimateLength(of track: DRTrack!) -> UInt64 { UInt64(blockCount) }

    func prepare(_ track: DRTrack!, for burn: DRBurn!, toMedia mediaInfo: [AnyHashable: Any]!) -> Bool { openFile() }

    func cleanupTrack(afterBurn track: DRTrack!) { closeFile() }

    func producePreGap(for track: DRTrack!, intoBuffer buffer: UnsafeMutablePointer<CChar>!, length bufferLength: UInt32, atAddress address: UInt64, blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> UInt32 {
        memset(buffer, 0, Int(bufferLength))
        return bufferLength
    }

    func produceData(for track: DRTrack!, intoBuffer buffer: UnsafeMutablePointer<CChar>!, length bufferLength: UInt32, atAddress address: UInt64, blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> UInt32 {
        guard fd >= 0 else { return 0 }
        var filled = 0
        while filled < Int(bufferLength) {
            let n = pread(fd, buffer + filled, Int(bufferLength) - filled, off_t(offset))
            if n < 0 { return 0 }
            if n == 0 { break }
            filled += n
            offset += Int64(n)
        }
        // Pad the final partial block with zeros.
        let block = Int(blockSize)
        if block > 0, filled % block != 0 {
            let padding = block - filled % block
            memset(buffer + filled, 0, padding)
            filled += padding
        }
        return UInt32(filled)
    }

    func prepareTrack(forVerification track: DRTrack!) -> Bool { openFile() }

    func verifyPreGap(for track: DRTrack!, inBuffer buffer: UnsafePointer<CChar>!, length bufferLength: UInt32, atAddress address: UInt64, blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> Bool { true }

    func verifyData(for track: DRTrack!, inBuffer buffer: UnsafePointer<CChar>!, length bufferLength: UInt32, atAddress address: UInt64, blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> Bool { true }

    func cleanupTrack(afterVerification track: DRTrack!) -> Bool {
        closeFile()
        return true
    }
}
