import CryptoKit
import Foundation

/// A checksum algorithm and its manifest format. Generator and verifier share it, so
/// adding another algorithm (for example SHA-512) is a new case.
public enum ChecksumAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case sha256

    public var id: String { rawValue }

    /// Name of the manifest written to the source root (and therefore onto the disc).
    public var manifestFileName: String {
        switch self {
        case .sha256: "checksums.sha256"
        }
    }

    /// The command that checks the manifest by hand: `cd <disc> && <command>`.
    public var manualCheckCommand: String {
        switch self {
        case .sha256: "shasum -a 256 -c \(manifestFileName)"
        }
    }

    public func makeHasher() -> any StreamingHasher {
        switch self {
        case .sha256: SHA256Hasher()
        }
    }

    /// One manifest line in `shasum` format: `<hex>  ./relative/path`.
    public func manifestLine(digest: String, relativePath: String) -> String {
        "\(digest)  ./\(relativePath)"
    }

    /// Parses a `shasum`-format line. Returns the relative path without "./".
    public func parseManifestLine(_ line: some StringProtocol) -> (digest: String, relativePath: String)? {
        guard let separator = line.range(of: "  ") else { return nil }
        let digest = String(line[line.startIndex..<separator.lowerBound])
        var path = String(line[separator.upperBound...])
        if path.hasPrefix("*") { path.removeFirst() } // shasum binary-mode marker
        if path.hasPrefix("./") { path.removeFirst(2) }
        guard digest.count == digestHexLength,
              digest.allSatisfy(\.isHexDigit),
              !path.isEmpty else { return nil }
        return (digest.lowercased(), path)
    }

    public var digestHexLength: Int {
        switch self {
        case .sha256: 64
        }
    }
}

public protocol StreamingHasher {
    mutating func update(_ bytes: UnsafeRawBufferPointer)
    mutating func finalizeHex() -> String
}

struct SHA256Hasher: StreamingHasher {
    private var hasher = SHA256()

    mutating func update(_ bytes: UnsafeRawBufferPointer) { hasher.update(bufferPointer: bytes) }

    mutating func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Streams a file through a hasher in fixed-size chunks.
enum FileHasher {
    static let chunkSize = 8 * 1024 * 1024

    /// `onBytes` is called after each chunk with the number of bytes just read.
    static func hash(
        _ url: URL,
        algorithm: ChecksumAlgorithm,
        onBytes: (Int) -> Void
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = algorithm.makeHasher()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            data.withUnsafeBytes { hasher.update($0) }
            onBytes(data.count)
        }
        return hasher.finalizeHex()
    }
}
