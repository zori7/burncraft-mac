import Foundation
import Observation

/// Runs a list of steps in order and publishes their state for the UI.
@MainActor
@Observable
public final class PipelineRunner {
    public struct StepStatus: Identifiable, Sendable, Equatable {
        public let id: StepID
        public let title: String
        public var state: StepState
        public var detail: String?
        public var startedAt: Date?
        public var finishedAt: Date?
    }

    public enum Outcome: Sendable, Equatable {
        case succeeded
        case failed(String)
        case cancelled
    }

    public private(set) var steps: [StepStatus] = []
    public private(set) var logLines: [String] = []
    public private(set) var isRunning = false
    public private(set) var lastOutcome: Outcome?
    public private(set) var pendingConfirmation: ConfirmationRequest?

    public let services: PipelineServices
    /// When set, confirmations are answered automatically (tests, scripting).
    private let autoConfirm: Bool?
    private let logFile: LogFile?
    private var task: Task<Outcome, Never>?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?

    public init(services: PipelineServices, autoConfirm: Bool? = nil, logFile: LogFile? = nil) {
        self.services = services
        self.autoConfirm = autoConfirm
        self.logFile = logFile
    }

    public static func standardSteps() -> [any PipelineStep] {
        [SizeCheckStep(), CleanStep(), ChecksumStep(), BuildImageStep(), BurnStep(), VerifyStep()]
    }

    /// Starts a run in the background. Ignored while another run is active.
    public func start(
        job: ArchiveJob,
        steps: [any PipelineStep] = PipelineRunner.standardSteps(),
        onFinish: (@MainActor (Outcome) -> Void)? = nil
    ) {
        guard !isRunning else { return }
        task = Task {
            let outcome = await run(job: job, steps: steps)
            onFinish?(outcome)
            return outcome
        }
    }

    public func cancel() {
        task?.cancel()
        answerConfirmation(false)
    }

    public func answerConfirmation(_ accepted: Bool) {
        pendingConfirmation = nil
        confirmationContinuation?.resume(returning: accepted)
        confirmationContinuation = nil
    }

    @discardableResult
    public func run(job: ArchiveJob, steps definitions: [any PipelineStep] = PipelineRunner.standardSteps()) async -> Outcome {
        isRunning = true
        lastOutcome = nil
        defer { isRunning = false }

        steps = definitions.map { step in
            let enabled = step.isEnabled(for: job) && !job.skippedSteps.contains(step.id)
            return StepStatus(id: step.id, title: step.title, state: enabled ? .pending : .skipped)
        }
        appendLog("— \(AppInfo.name) run: \(job.sourceFolder.path) → \(job.volumeName)")

        var outcome = Outcome.succeeded
        for (index, step) in definitions.enumerated() where steps[index].state == .pending {
            if Task.isCancelled {
                outcome = .cancelled
                break
            }
            steps[index].state = .running(progress: nil)
            steps[index].startedAt = .now
            appendLog("▶︎ \(step.title)")
            do {
                try await step.run(makeContext(job: job, stepIndex: index))
                try Task.checkCancellation()
                finish(index, .done)
            } catch is CancellationError {
                finish(index, .cancelled)
                outcome = .cancelled
                break
            } catch {
                let message = error.localizedDescription
                finish(index, Task.isCancelled ? .cancelled : .failed(message))
                outcome = Task.isCancelled ? .cancelled : .failed(message)
                break
            }
        }

        for index in steps.indices where steps[index].state == .pending {
            steps[index].state = .skipped
        }
        switch outcome {
        case .succeeded: appendLog("✅ Finished")
        case .failed(let message): appendLog("❌ \(message)")
        case .cancelled: appendLog("⏹ Cancelled")
        }
        lastOutcome = outcome
        return outcome
    }

    private func finish(_ index: Int, _ state: StepState) {
        steps[index].state = state
        steps[index].finishedAt = .now
        if state == .done { steps[index].detail = nil }
    }

    private func makeContext(job: ArchiveJob, stepIndex: Int) -> PipelineContext {
        PipelineContext(
            job: job,
            services: services,
            progress: { [weak self] fraction, detail in
                Task { @MainActor in self?.updateProgress(stepIndex, fraction, detail) }
            },
            log: { [weak self] message in
                await self?.appendLog(message)
            },
            confirm: { [weak self] request in
                await self?.requestConfirmation(request) ?? false
            })
    }

    private func updateProgress(_ index: Int, _ fraction: Double?, _ detail: String?) {
        guard steps.indices.contains(index), case .running = steps[index].state else { return }
        steps[index].state = .running(progress: fraction.map { min(max($0, 0), 1) })
        if let detail { steps[index].detail = detail }
    }

    private func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        if let autoConfirm { return autoConfirm }
        if Task.isCancelled { return false }
        answerConfirmation(false) // never leave an older request hanging
        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
            pendingConfirmation = request
        }
    }

    public func appendLog(_ message: String) {
        let line = "[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)"
        logLines.append(line)
        logFile?.append(line)
    }
}
