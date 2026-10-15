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

            Section("Steps") {
                ForEach(PipelineRunner.standardSteps().filter(\.hasStepToggle), id: \.id) { step in
                    Toggle(isOn: Binding(
                        get: { model.isStepOn(step.id) },
                        set: { model.setStep(step.id, on: $0) })
                    ) {
                        Text(step.title)
                        if step.id == .clean {
                            Text("dot_clean and .DS_Store removal. Changes files in the source folder.")
                        }
                    }
                }
                Text("Disc verification is set by Verify above.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.runner.isRunning)
        .overlay(alignment: .bottom) {
            if let hint = model.hint {
                HintBanner(message: hint) { model.dismissHint() }
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.hint)
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

private struct HintBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(radius: 4, y: 2)
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
