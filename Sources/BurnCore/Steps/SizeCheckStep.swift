import Foundation

/// Compares the source size with the disc (inserted blank disc, else the media type's limit).
public struct SizeCheckStep: PipelineStep {
    public init() {}

    public let id = StepID.sizeCheck
    public let title = "Check size"

    public func run(_ context: PipelineContext) async throws {
        let job = context.job
        context.progress(nil, "Measuring \(job.sourceFolder.lastPathComponent)…")
        let size = try FileTree.allocatedSize(of: job.sourceFolder)
        let limit = await Self.limit(for: job, burner: context.services.burner)
        await context.log("Source size: \(ByteFormat.gib(size)) (limit \(ByteFormat.gib(limit.bytes)), \(limit.origin))")

        if Self.exceeds(size: size, limit: limit.bytes) {
            let proceed = await context.confirm(ConfirmationRequest(
                title: "Source is larger than the disc",
                message: "\(ByteFormat.gib(size)) exceeds the \(ByteFormat.gib(limit.bytes)) limit (\(limit.origin)). Proceed anyway?",
                confirmLabel: "Proceed anyway",
                isDestructive: true))
            guard proceed else { throw PipelineError.declined("source exceeds the disc limit") }
            await context.log("⚠️ Continuing although the source exceeds the limit.")
        }
        context.progress(1, ByteFormat.gib(size))
    }

    public static func exceeds(size: Int64, limit: Int64) -> Bool { size > limit }

    @MainActor
    static func limit(for job: ArchiveJob, burner: any DiscBurning) -> (bytes: Int64, origin: String) {
        if let media = burner.currentMedia(), media.isBlank, let free = media.freeBytes, free > 0 {
            return (free, "free space on the inserted disc")
        }
        return (job.media.recommendedLimitBytes, job.media.displayName)
    }
}
