import Foundation

public struct BuildImageStep: PipelineStep {
    public init() {}

    public let id = StepID.buildImage
    public let title = "Build disc image"

    public func run(_ context: PipelineContext) async throws {
        let job = context.job
        let format = job.imageFormat
        if let problem = format.validate(volumeName: job.volumeName) {
            throw PipelineError.invalidInput(problem)
        }

        let output = job.imageURL
        if FileManager.default.fileExists(atPath: output.path) {
            let overwrite = await context.confirm(ConfirmationRequest(
                title: "Image already exists",
                message: "\(output.path) already exists. Replace it?",
                confirmLabel: "Replace",
                isDestructive: true))
            guard overwrite else { throw PipelineError.declined("existing image kept") }
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.createDirectory(at: job.outputFolder, withIntermediateDirectories: true)

        await context.log("Building \(format.displayName) image \(output.lastPathComponent)…")
        try await format.makeImage(
            source: job.sourceFolder,
            volumeName: job.volumeName,
            output: output,
            runner: context.services.commandRunner
        ) { fraction in
            context.progress(fraction, nil)
        }

        let size = Self.fileSize(output)
        await context.log("Image ready: \(output.path) (\(ByteFormat.gib(size)))")
        if size > job.media.capacityBytes {
            throw PipelineError.doesNotFit(
                "Image is \(ByteFormat.gib(size)), larger than \(job.media.displayName) (\(ByteFormat.gib(job.media.capacityBytes))).")
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
