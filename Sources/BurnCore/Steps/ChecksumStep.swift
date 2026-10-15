import Foundation

public struct ChecksumStep: PipelineStep {
    public init() {}

    public let id = StepID.checksums
    public let title = "Generate checksums"

    public func run(_ context: PipelineContext) async throws {
        let generator = ChecksumGenerator(algorithm: context.job.checksumAlgorithm)
        let manifest = try generator.generate(in: context.job.sourceFolder) { p in
            context.progress(p.fraction, p.currentFile)
        }
        let count = (try? String(contentsOf: manifest, encoding: .utf8))?.split(separator: "\n").count ?? 0
        await context.log("Wrote \(manifest.lastPathComponent) (\(count) files).")
    }
}
