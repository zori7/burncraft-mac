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
        if let mismatch = Self.mediaMismatch(inserted: media, expected: job.media) {
            await context.log("⚠️ \(mismatch)")
            let proceed = await context.confirm(ConfirmationRequest(
                title: "Disc doesn't match Media",
                message: "\(mismatch) Continue with this disc?",
                confirmLabel: "Continue Anyway",
                isDestructive: true))
            guard proceed else { throw PipelineError.declined("inserted disc doesn't match Media") }
            await context.log("Continuing with the inserted disc.")
        }

        // No final "Burn?" question: the settings were chosen before Start, and the
        // risky cases (size, existing image, mismatched disc) already ask. This keeps
        // long runs unattended.
        let driveName = await burner.currentDrive()?.name ?? "the drive"
        await context.log("Burning \(image.lastPathComponent) (\(ByteFormat.gib(imageSize))) to \(media.typeName) in \(driveName).")

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

    /// Describes how the inserted disc differs from the Media setting, or nil if it matches.
    static func mediaMismatch(inserted: MediaStatus, expected: MediaType) -> String? {
        if let detected = MediaType.matching(inserted) {
            return detected == expected ? nil
                : "Inserted disc looks like \(detected.displayName), but Media is set to \(expected.displayName)."
        }
        return expected.matches(discRecordingType: inserted.discRecordingType) ? nil
            : "Inserted disc (\(inserted.typeName)) is not a \(expected.displayName)."
    }
}
