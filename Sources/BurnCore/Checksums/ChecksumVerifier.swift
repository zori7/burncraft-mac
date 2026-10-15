import Foundation

public struct VerificationReport: Sendable, Equatable {
    public var verified: [String] = []
    public var mismatched: [String] = []
    public var missing: [String] = []
    /// 1-based line numbers of manifest lines that could not be parsed.
    public var malformedLines: [Int] = []

    public var isSuccess: Bool { mismatched.isEmpty && missing.isEmpty && malformedLines.isEmpty && !verified.isEmpty }

    public var summary: String {
        var parts = ["\(verified.count) OK"]
        if !mismatched.isEmpty { parts.append("\(mismatched.count) mismatched") }
        if !missing.isEmpty { parts.append("\(missing.count) missing") }
        if !malformedLines.isEmpty { parts.append("\(malformedLines.count) unreadable manifest lines") }
        return parts.joined(separator: ", ")
    }
}

public enum VerificationError: LocalizedError, Sendable {
    case manifestMissing(URL)
    case failed(VerificationReport)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing(let url): "No checksum manifest at \(url.path)"
        case .failed(let report): "Verification failed: \(report.summary)"
        }
    }
}

/// Re-hashes the files listed in a manifest (the app's `shasum -a 256 -c`).
public struct ChecksumVerifier: Sendable {
    public let algorithm: ChecksumAlgorithm

    public init(algorithm: ChecksumAlgorithm = .sha256) { self.algorithm = algorithm }

    public func verify(root: URL, progress: @Sendable (HashProgress) -> Void = { _ in }) throws -> VerificationReport {
        let manifest = root.appending(path: algorithm.manifestFileName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw VerificationError.manifestMissing(manifest)
        }
        let text = try String(contentsOf: manifest, encoding: .utf8)

        var report = VerificationReport()
        var entries: [(digest: String, path: String, url: URL, size: Int64)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let parsed = algorithm.parseManifestLine(line) else {
                report.malformedLines.append(index + 1)
                continue
            }
            let url = root.appending(path: parsed.relativePath, directoryHint: .notDirectory)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                report.missing.append(parsed.relativePath)
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            entries.append((parsed.digest, parsed.relativePath, url, size))
        }

        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        var done: Int64 = 0
        for entry in entries {
            progress(HashProgress(bytesDone: done, bytesTotal: total, currentFile: entry.path))
            let digest = try FileHasher.hash(entry.url, algorithm: algorithm) { count in
                done += Int64(count)
                progress(HashProgress(bytesDone: done, bytesTotal: total, currentFile: entry.path))
            }
            if digest == entry.digest {
                report.verified.append(entry.path)
            } else {
                report.mismatched.append(entry.path)
            }
        }
        return report
    }
}
