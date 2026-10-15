import Foundation

/// What to do when the image file already exists.
public enum ExistingImageChoice: Sendable, Equatable {
    /// Ask during the build step.
    case ask
    /// Delete it and build a new one.
    case replace
    /// Burn it as it is: cleanup, checksums and the build are skipped.
    case reuse
}

/// Everything a pipeline run needs. Built by the UI, read by the steps.
public struct ArchiveJob: Sendable {
    public var sourceFolder: URL
    public var outputFolder: URL
    public var volumeName: String
    public var media: MediaType
    public var imageFormatID: String
    public var checksumAlgorithm: ChecksumAlgorithm
    public var verification: VerificationMode
    public var cleanMetadata: Bool
    public var burnSpeed: Int
    /// Steps the user turned off (for example, burn an already-built image).
    public var skippedSteps: Set<StepID>
    public var existingImage: ExistingImageChoice = .ask

    public init(
        sourceFolder: URL,
        outputFolder: URL,
        volumeName: String,
        media: MediaType = .default,
        imageFormatID: String = ImageFormats.default.id,
        checksumAlgorithm: ChecksumAlgorithm = .sha256,
        verification: VerificationMode = .checksums,
        cleanMetadata: Bool = true,
        burnSpeed: Int = AppInfo.defaultBurnSpeed,
        skippedSteps: Set<StepID> = []
    ) {
        self.sourceFolder = sourceFolder
        self.outputFolder = outputFolder
        self.volumeName = volumeName
        self.media = media
        self.imageFormatID = imageFormatID
        self.checksumAlgorithm = checksumAlgorithm
        self.verification = verification
        self.cleanMetadata = cleanMetadata
        self.burnSpeed = burnSpeed
        self.skippedSteps = skippedSteps
    }

    /// Steps that only produce the image's contents; pointless when reusing an image.
    public static let imageInputSteps: Set<StepID> = [.clean, .checksums, .buildImage]

    /// Steps the run skips: the user's choices plus, when reusing an image, the steps
    /// that would produce it.
    public var effectiveSkippedSteps: Set<StepID> {
        existingImage == .reuse ? skippedSteps.union(Self.imageInputSteps) : skippedSteps
    }

    /// True when the image would be built but a file is already at `imageURL`, so the
    /// user should choose (before the run starts) between reusing and replacing it.
    public var needsExistingImageChoice: Bool {
        existingImage == .ask
            && !skippedSteps.contains(.buildImage)
            && FileManager.default.fileExists(atPath: imageURL.path)
    }

    public var imageFormat: any ImageFormat {
        ImageFormats.format(id: imageFormatID) ?? ImageFormats.default
    }

    public var imageURL: URL {
        outputFolder.appending(path: "\(volumeName).\(imageFormat.fileExtension)", directoryHint: .notDirectory)
    }
}
