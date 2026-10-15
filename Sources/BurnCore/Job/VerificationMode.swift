/// How the burned disc is verified. Each check reads the whole disc once, so the
/// default runs only the checksum check instead of doubling the time.
public enum VerificationMode: String, CaseIterable, Identifiable, Sendable {
    /// Re-hash files on the mounted disc against checksums.sha256 (default).
    case checksums
    /// Drive block-compare against the image (what `drutil burn` does by default).
    case drive
    case both
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .checksums: "Checksums only"
        case .drive: "Drive verify only"
        case .both: "Drive + checksums"
        case .none: "None"
        }
    }

    public var usesDriveVerify: Bool { self == .drive || self == .both }
    public var usesChecksumVerify: Bool { self == .checksums || self == .both }
}
