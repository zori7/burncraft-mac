import BurnCore
import SwiftUI

struct StepListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.runner.steps.isEmpty {
                Text("Choose a source folder and press Start.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.runner.steps) { step in
                StepRow(step: step)
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 220)
    }
}

private struct StepRow: View {
    let step: PipelineRunner.StepStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.title).fontWeight(isRunning ? .semibold : .regular)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timing(now: context.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if case .running(let progress) = step.state {
                    if let progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                if let detail = step.detail, isRunning {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if case .failed(let message) = step.state {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var isRunning: Bool {
        if case .running = step.state { true } else { false }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.orange)
        }
    }

    private func timing(now: Date) -> String {
        guard let start = step.startedAt else { return "" }
        let elapsed = (step.finishedAt ?? now).timeIntervalSince(start)
        var text = Duration.seconds(elapsed).formatted(.time(pattern: .hourMinuteSecond))
        if case .running(let progress?) = step.state, progress > 0.02, step.finishedAt == nil {
            let remaining = elapsed / progress - elapsed
            text += " · ~\(Duration.seconds(remaining).formatted(.time(pattern: .hourMinuteSecond))) left"
        }
        return text
    }
}
