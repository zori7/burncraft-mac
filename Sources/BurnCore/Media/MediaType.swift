import Foundation

/// A kind of writable disc. Add DVD/CD support by adding entries to `all`.
public struct MediaType: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// Physical data capacity; an image larger than this cannot be burned.
    public let capacityBytes: Int64
    /// Conservative source-size limit used by the size check (make_archive.sh used 46.0 GiB for BD-R DL).
    public let recommendedLimitBytes: Int64
    /// DiscRecording media type strings (`DRDeviceMediaType…`) this entry matches.
    public let discRecordingTypes: [String]
    /// Image formats (`ImageFormat.id`) allowed on this media.
    public let imageFormatIDs: [String]
    /// The drive's 1x write speed in KB/s; DiscRecording speeds are expressed in KB/s.
    public let oneXSpeedKBps: Double
    public let speedChoices: [Int]

    public static let gib: Int64 = 1_073_741_824

    public func speedKBps(forFactor factor: Int) -> Double { Double(factor) * oneXSpeedKBps }

    public func speedFactor(forKBps kbps: Double) -> Int { Int((kbps / oneXSpeedKBps).rounded()) }

    public func matches(discRecordingType: String?) -> Bool {
        guard let discRecordingType else { return false }
        return discRecordingTypes.contains(discRecordingType)
    }
}

extension MediaType {
    // DiscRecording's own constant values (DRDeviceMediaTypeBDR / …BDRE), kept as
    // strings so this file doesn't need the framework.
    private static let drBDR = "DRDeviceMediaTypeBDR"
    private static let drBDRE = "DRDeviceMediaTypeBDRE"
    private static let blurayOneX = 4496.0
    private static let bluraySpeeds = [2, 4, 6, 8, 12]
    private static let blurayFormats = [UDFImageFormat.udf250.id]

    public static let bdr25 = MediaType(
        id: "bd-r-25", displayName: "BD-R 25 GB",
        capacityBytes: 12_219_392 * 2048, recommendedLimitBytes: 23 * gib,
        discRecordingTypes: [drBDR], imageFormatIDs: blurayFormats,
        oneXSpeedKBps: blurayOneX, speedChoices: bluraySpeeds)

    public static let bdr50 = MediaType(
        id: "bd-r-dl-50", displayName: "BD-R DL 50 GB",
        capacityBytes: 24_438_784 * 2048, recommendedLimitBytes: 46 * gib,
        discRecordingTypes: [drBDR], imageFormatIDs: blurayFormats,
        oneXSpeedKBps: blurayOneX, speedChoices: bluraySpeeds)

    public static let bdxl100 = MediaType(
        id: "bd-r-xl-100", displayName: "BD-R XL 100 GB",
        capacityBytes: 48_878_592 * 2048, recommendedLimitBytes: 92 * gib,
        discRecordingTypes: [drBDR], imageFormatIDs: blurayFormats,
        oneXSpeedKBps: blurayOneX, speedChoices: [2, 4, 6])

    public static let bdre25 = MediaType(
        id: "bd-re-25", displayName: "BD-RE 25 GB",
        capacityBytes: 11_826_176 * 2048, recommendedLimitBytes: 22 * gib,
        discRecordingTypes: [drBDRE], imageFormatIDs: blurayFormats,
        oneXSpeedKBps: blurayOneX, speedChoices: [2])

    public static let all: [MediaType] = [bdr25, bdr50, bdxl100, bdre25]
    public static let `default` = bdr50

    public static func media(id: String) -> MediaType? { all.first { $0.id == id } }
}
