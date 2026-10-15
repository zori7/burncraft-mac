import Foundation

public struct HashProgress: Sendable {
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let currentFile: String

    public var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 1 }
}

/// Writes the checksum manifest into the source root, in a format `shasum -c` accepts.
public struct ChecksumGenerator: Sendable {
    public let algorithm: ChecksumAlgorithm

    public init(algorithm: ChecksumAlgorithm = .sha256) { self.algorithm = algorithm }

    /// Returns the manifest URL. On error or cancellation no partial manifest is left behind.
    @discardableResult
    public func generate(in root: URL, progress: @Sendable (HashProgress) -> Void = { _ in }) throws -> URL {
        let manifest = root.appending(path: algorithm.manifestFileName, directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: manifest)

        let files = try FileTree.regularFiles(in: root, excludingNames: [algorithm.manifestFileName])
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var done: Int64 = 0
        var lines: [String] = []
        lines.reserveCapacity(files.count)

        for file in files {
            let url = root.appending(path: file.relativePath, directoryHint: .notDirectory)
            progress(HashProgress(bytesDone: done, bytesTotal: total, currentFile: file.relativePath))
            let digest = try FileHasher.hash(url, algorithm: algorithm) { count in
                done += Int64(count)
                progress(HashProgress(bytesDone: done, bytesTotal: total, currentFile: file.relativePath))
            }
            lines.append(algorithm.manifestLine(digest: digest, relativePath: file.relativePath))
        }

        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: manifest, options: .atomic)
        return manifest
    }
}
