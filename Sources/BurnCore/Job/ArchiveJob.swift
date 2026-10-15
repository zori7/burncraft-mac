import Foundation

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

    public var imageFormat: any ImageFormat {
        ImageFormats.format(id: imageFormatID) ?? ImageFormats.default
    }

    public var imageURL: URL {
        outputFolder.appending(path: "\(volumeName).\(imageFormat.fileExtension)", directoryHint: .notDirectory)
    }
}
