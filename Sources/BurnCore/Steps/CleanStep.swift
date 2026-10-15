import Foundation

/// `dot_clean -m` plus deleting `.DS_Store`, like make_archive.sh. Changes the source folder.
public struct CleanStep: PipelineStep {
    public init() {}

    public let id = StepID.clean
    public let title = "Clean Apple metadata"
    static let dotClean = "/usr/sbin/dot_clean"

    public func isEnabled(for job: ArchiveJob) -> Bool { job.cleanMetadata }

    public func run(_ context: PipelineContext) async throws {
        let source = context.job.sourceFolder
        context.progress(nil, "dot_clean -m")
        try await context.services.commandRunner.run(Self.dotClean, ["-m", source.path])
        let removed = try Self.removeDSStoreFiles(in: source)
        await context.log("Removed \(removed) .DS_Store file(s).")
        context.progress(1, nil)
    }

    @discardableResult
    public static func removeDSStoreFiles(in root: URL) throws -> Int {
        let files = FileTree.files(named: ".DS_Store", in: root)
        for file in files { try FileManager.default.removeItem(at: file) }
        return files.count
    }
}
