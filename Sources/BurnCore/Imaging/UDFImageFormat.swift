import Foundation

/// UDF image built with `hdiutil makehybrid -udf -udf-version <version>`.
public struct UDFImageFormat: ImageFormat {
    public static let udf250 = UDFImageFormat(version: "2.50")

    public static let maxVolumeNameLength = 30
    static let hdiutil = "/usr/bin/hdiutil"

    public let version: String

    public var id: String { "udf-\(version)" }
    public var displayName: String { "UDF \(version)" }
    public var fileExtension: String { "iso" }

    public func validate(volumeName: String) -> String? {
        if volumeName.isEmpty { return "Volume name is empty." }
        if volumeName.count > Self.maxVolumeNameLength {
            return "Volume name is longer than \(Self.maxVolumeNameLength) characters."
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        if volumeName.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use only letters, digits, \"_\" and \"-\" in the volume name."
        }
        return nil
    }

    public func arguments(source: URL, volumeName: String, output: URL) -> [String] {
        ["makehybrid", "-o", output.path, source.path,
         "-udf", "-udf-version", version,
         "-default-volume-name", volumeName]
    }

    public func makeImage(
        source: URL,
        volumeName: String,
        output: URL,
        runner: any CommandRunning,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        // makehybrid has no progress output, so poll the image size against the source size.
        let expected = (try? FileTree.allocatedSize(of: source)) ?? 0
        let poller = Task.detached {
            while !Task.isCancelled {
                let written = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
                progress(expected > 0 ? min(0.99, Double(written) / Double(expected)) : nil)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { poller.cancel() }

        do {
            try await runner.run(Self.hdiutil, arguments(source: source, volumeName: volumeName, output: output))
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
    }
}
