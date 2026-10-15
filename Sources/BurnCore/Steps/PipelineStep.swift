import Foundation

public struct StepID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let sizeCheck = StepID(rawValue: "size-check")
    public static let clean = StepID(rawValue: "clean")
    public static let checksums = StepID(rawValue: "checksums")
    public static let buildImage = StepID(rawValue: "build-image")
    public static let burn = StepID(rawValue: "burn")
    public static let verify = StepID(rawValue: "verify")
}

public enum StepState: Sendable, Equatable {
    case pending
    /// `progress` is nil when the step can't tell how far along it is.
    case running(progress: Double?)
    case done
    case skipped
    case failed(String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .pending, .running: false
        case .done, .skipped, .failed, .cancelled: true
        }
    }
}

public struct ConfirmationRequest: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let confirmLabel: String
    public let isDestructive: Bool

    public init(title: String, message: String, confirmLabel: String, isDestructive: Bool = false) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.isDestructive = isDestructive
    }
}

/// The outside world the steps talk to. Tests swap in fakes.
public struct PipelineServices: Sendable {
    public var commandRunner: any CommandRunning
    public var burner: any DiscBurning
    public var mountWatcher: any MountWatching
    public var mountTimeout: Duration

    public init(
        commandRunner: any CommandRunning,
        burner: any DiscBurning,
        mountWatcher: any MountWatching,
        mountTimeout: Duration = AppInfo.mountTimeout
    ) {
        self.commandRunner = commandRunner
        self.burner = burner
        self.mountWatcher = mountWatcher
        self.mountTimeout = mountTimeout
    }
}

public struct PipelineContext: Sendable {
    public let job: ArchiveJob
    public let services: PipelineServices
    /// Reports step progress (0...1, or nil when indeterminate) and an optional detail line.
    public let progress: @Sendable (Double?, String?) -> Void
    public let log: @Sendable (String) async -> Void
    /// Asks the user; returns false when they decline or the run is cancelled.
    public let confirm: @Sendable (ConfirmationRequest) async -> Bool
}

public enum PipelineError: LocalizedError, Sendable, Equatable {
    case declined(String)
    case invalidInput(String)
    case doesNotFit(String)

    public var errorDescription: String? {
        switch self {
        case .declined(let what): "Stopped: \(what)"
        case .invalidInput(let message): message
        case .doesNotFit(let message): message
        }
    }
}

/// One stage of the pipeline. Add a stage by writing a conforming type and listing it
/// in `PipelineRunner.standardSteps()`.
public protocol PipelineStep: Sendable {
    var id: StepID { get }
    var title: String { get }
    /// False when another setting already turns the step on or off (for example the
    /// verification mode), so the UI shouldn't offer a separate on/off switch for it.
    var hasStepToggle: Bool { get }
    func isEnabled(for job: ArchiveJob) -> Bool
    func run(_ context: PipelineContext) async throws
}

extension PipelineStep {
    public var hasStepToggle: Bool { true }
    public func isEnabled(for job: ArchiveJob) -> Bool { true }
}
