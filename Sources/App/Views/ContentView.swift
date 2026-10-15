import BurnCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            SetupForm()
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 480)
            VStack(spacing: 0) {
                DriveStatusView()
                Divider()
                StepListView()
                Divider()
                LogView()
                    .frame(minHeight: 160)
                Divider()
                ActionBar()
            }
            .frame(minWidth: 480)
        }
        .alert(
            model.runner.pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { model.runner.pendingConfirmation != nil },
                set: { if !$0 { model.runner.answerConfirmation(false) } }),
            presenting: model.runner.pendingConfirmation
        ) { request in
            Button(request.confirmLabel, role: request.isDestructive ? .destructive : nil) {
                model.runner.answerConfirmation(true)
            }
            Button("Cancel", role: .cancel) { model.runner.answerConfirmation(false) }
        } message: { request in
            Text(request.message)
        }
    }
}

private struct ActionBar: View {
    @Environment(AppModel.self) private var model
    @State private var confirmCancelBurn = false

    var body: some View {
        HStack {
            if model.runner.isRunning {
                Button("Cancel", role: .cancel) {
                    if model.isBurning { confirmCancelBurn = true } else { model.cancel() }
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button("Verify a Disc…", action: pickVerifyFolder)
                if model.lastImageURL != nil {
                    Button("Show Image") { model.revealImage() }
                    Button("Delete Image", role: .destructive) { model.deleteImage() }
                }
            }
            Spacer()
            if let outcome = model.runner.lastOutcome, !model.runner.isRunning {
                OutcomeLabel(outcome: outcome)
            }
            Button("Start") { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
        }
        .alert(
            "Image already exists",
            isPresented: Binding(
                get: { model.jobAwaitingImageChoice != nil },
                set: { if !$0 { model.resolveExistingImage(nil) } }),
            presenting: model.jobAwaitingImageChoice
        ) { _ in
            Button("Use Existing") { model.resolveExistingImage(.reuse) }
            Button("Replace", role: .destructive) { model.resolveExistingImage(.replace) }
            Button("Cancel", role: .cancel) { model.resolveExistingImage(nil) }
        } message: { job in
            Text("""
                \(job.imageURL.path) already exists.

                Use Existing burns that image as it is and skips cleanup, checksums and \
                building. It won't include changes made to the folder since it was built.
                Replace builds a new image from the folder.
                """)
        }
        .padding(12)
        .confirmationDialog("Stop the burn?", isPresented: $confirmCancelBurn) {
            Button("Stop Burn", role: .destructive) { model.cancel() }
        } message: {
            Text("Stopping a burn in progress will most likely leave the disc unusable.")
        }
    }

    private func pickVerifyFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(filePath: "/Volumes", directoryHint: .isDirectory)
        panel.message = "Choose a disc (or folder) that contains its checksum manifest."
        if panel.runModal() == .OK, let url = panel.url { model.verify(folder: url) }
    }
}

private struct OutcomeLabel: View {
    let outcome: PipelineRunner.Outcome

    var body: some View {
        switch outcome {
        case .succeeded: Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Label("Cancelled", systemImage: "stop.circle").foregroundStyle(.secondary)
        }
    }
}
