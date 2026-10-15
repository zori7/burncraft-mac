import Foundation

public struct BurnStep: PipelineStep {
    public init() {}

    public let id = StepID.burn
    public let title = "Burn disc"

    public func run(_ context: PipelineContext) async throws {
        let job = context.job
        let burner = context.services.burner
        let image = job.imageURL
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw PipelineError.invalidInput("No image at \(image.path). Enable \"Build disc image\" or build it first.")
        }
        let imageSize = BuildImageStep.fileSize(image)

        context.progress(nil, "Waiting for a blank disc…")
        let media = try await burner.waitForBlankMedia(log: context.log)
        if let free = media.freeBytes, imageSize > free {
            throw PipelineError.doesNotFit("Image (\(ByteFormat.gib(imageSize))) is larger than the disc's free space (\(ByteFormat.gib(free))).")
        }
        if !job.media.matches(discRecordingType: media.discRecordingType) {
            await context.log("⚠️ Inserted disc (\(media.typeName)) is not a \(job.media.displayName).")
        }

        let driveName = await burner.currentDrive()?.name ?? "the drive"
        let proceed = await context.confirm(ConfirmationRequest(
            title: "Burn disc?",
            message: """
                \(image.lastPathComponent) (\(ByteFormat.gib(imageSize)))
                to \(media.typeName) in \(driveName) at \(job.burnSpeed)x.
                Drive verification: \(job.verification.usesDriveVerify ? "on" : "off").
                """,
            confirmLabel: "Burn"))
        guard proceed else { throw PipelineError.declined("burn not confirmed") }

        let request = BurnRequest(
            image: image,
            speedKBps: job.media.speedKBps(forFactor: job.burnSpeed),
            driveVerify: job.verification.usesDriveVerify)
        await context.log("Burning at \(job.burnSpeed)x, drive verify \(request.driveVerify ? "on" : "off")…")

        try await withSleepPrevented(reason: "Burning \(job.volumeName)") {
            try await burner.burn(request) { update in
                context.progress(update.fraction, update.phase)
            }
        }
        await context.log("Burn finished.")
    }
}
