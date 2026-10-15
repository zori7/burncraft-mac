import Foundation

public enum MountError: LocalizedError, Sendable {
    case timedOut(volumeName: String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let name):
            "Volume \"\(name)\" did not mount. Eject and reinsert the disc, then run Verify."
        }
    }
}

/// Waits for a volume to appear. A protocol so tests can fake it.
public protocol MountWatching: Sendable {
    func waitForVolume(named name: String, timeout: Duration) async throws -> URL
}

public struct VolumeMountWatcher: MountWatching {
    public init() {}

    public func waitForVolume(named name: String, timeout: Duration) async throws -> URL {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let url = Self.mountedVolume(named: name) { return url }
            try await Task.sleep(for: .seconds(1))
        }
        throw MountError.timedOut(volumeName: name)
    }

    /// Matches by volume name, so "/Volumes/NAME 1" style mount points are found too.
    public static func mountedVolume(named name: String) -> URL? {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        return urls.first { (try? $0.resourceValues(forKeys: [.volumeNameKey]).volumeName) == name }
    }
}
