import BurnCore
import SwiftUI

struct SetupForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Source") {
                FolderField(title: "Folder", url: $model.sourceFolder, prompt: "Choose the folder to archive")
            }

            Section("Disc image") {
                TextField("Volume name", text: $model.volumeName)
                if let problem = model.volumeNameProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                FolderField(title: "Save to", url: $model.outputFolder, prompt: "Choose where to save the image")
                LabeledContent("Format", value: model.imageFormat.displayName)
            }

            Section("Disc") {
                Picker("Media", selection: $model.media) {
                    ForEach(MediaType.all) { Text($0.displayName).tag($0) }
                }
                Picker("Speed", selection: $model.burnSpeed) {
                    ForEach(model.speedChoices, id: \.self) { Text("\($0)x").tag($0) }
                }
                Picker("Verify", selection: $model.verification) {
                    ForEach(VerificationMode.allCases) { Text($0.displayName).tag($0) }
                }
                Text(verificationHint).font(.caption).foregroundStyle(.secondary)
            }

            Section("Options") {
                Toggle("Clean Apple metadata (dot_clean, .DS_Store)", isOn: $model.cleanMetadata)
                Text("Changes files in the source folder.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Steps") {
                ForEach(PipelineRunner.standardSteps(), id: \.id) { step in
                    Toggle(step.title, isOn: Binding(
                        get: { !model.skippedSteps.contains(step.id) },
                        set: { enabled in
                            if enabled { model.skippedSteps.remove(step.id) } else { model.skippedSteps.insert(step.id) }
                        }))
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.runner.isRunning)
    }

    private var verificationHint: String {
        switch model.verification {
        case .checksums: "Re-hashes every file on the mounted disc. One full read."
        case .drive: "Drive compares the disc with the image. Check checksums later with Verify a Disc…"
        case .both: "Drive compare plus checksum check. Two full reads."
        case .none: "No verification. You can still run Verify a Disc… later."
        }
    }
}

private struct FolderField: View {
    let title: String
    @Binding var url: URL?
    let prompt: String
    @State private var isTargeted = false

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(url?.path ?? "None")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .help(url?.path ?? "")
                Button("Choose…", action: choose)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first, first.hasDirectoryPath else { return false }
            url = first
            return true
        } isTargeted: { isTargeted = $0 }
        .background(isTargeted ? Color.accentColor.opacity(0.15) : .clear)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = prompt
        panel.directoryURL = url
        if panel.runModal() == .OK { url = panel.url }
    }
}
