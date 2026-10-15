import Foundation

/// A disc image format. Add a format by writing a conforming type and listing it in
/// `ImageFormats.all`; media types opt in via `MediaType.imageFormatIDs`.
public protocol ImageFormat: Sendable {
    var id: String { get }
    var displayName: String { get }
    var fileExtension: String { get }

    /// Returns a user-facing problem with the volume name, or nil if it is valid.
    func validate(volumeName: String) -> String?

    /// Builds the image. Must remove any partial output when it throws or is cancelled.
    func makeImage(
        source: URL,
        volumeName: String,
        output: URL,
        runner: any CommandRunning,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws
}

public enum ImageFormats {
    public static let all: [any ImageFormat] = [UDFImageFormat.udf250]
    public static let `default`: any ImageFormat = UDFImageFormat.udf250

    public static func format(id: String) -> (any ImageFormat)? { all.first { $0.id == id } }

    public static func formats(for media: MediaType) -> [any ImageFormat] {
        all.filter { media.imageFormatIDs.contains($0.id) }
    }
}
