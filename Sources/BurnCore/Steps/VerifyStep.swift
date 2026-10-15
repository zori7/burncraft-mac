import Foundation

/// Re-hashes the files on the burned disc (or any folder) against the manifest on it.
public struct VerifyStep: PipelineStep {
    public enum Target: Sendable {
        /// Wait for the job's volume name to mount (after a burn).
        case burnedVolume
        /// Verify an already-mounted disc or folder.
        case folder(URL)
    }

    public let target: Target

    public init(target: Target = .burnedVolume) { self.target = target }

    public let id = StepID.verify
    public let title = "Verify disc"
    /// Controlled by the verification mode instead.
    public let hasStepToggle = false

    public func isEnabled(for job: ArchiveJob) -> Bool {
        if case .folder = target { return true }
        return job.verification.usesChecksumVerify
    }

    public func run(_ context: PipelineContext) async throws {
        let root: URL
        switch target {
        case .folder(let url):
            root = url
        case .burnedVolume:
            let name = context.job.volumeName
            context.progress(nil, "Waiting for \(name) to mount…")
            root = try await context.services.mountWatcher.waitForVolume(named: name, timeout: context.services.mountTimeout)
        }

        await context.log("Verifying \(root.path)…")
        let verifier = ChecksumVerifier(algorithm: context.job.checksumAlgorithm)
        let report = try verifier.verify(root: root) { p in
            context.progress(p.fraction, p.currentFile)
        }
        await context.log("Verification: \(report.summary)")
        for path in report.mismatched { await context.log("  MISMATCH \(path)") }
        for path in report.missing { await context.log("  MISSING  \(path)") }
        for line in report.malformedLines { await context.log("  UNREADABLE manifest line \(line)") }
        guard report.isSuccess else { throw VerificationError.failed(report) }
    }
}
