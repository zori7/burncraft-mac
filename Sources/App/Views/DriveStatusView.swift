import BurnCore
import SwiftUI

struct DriveStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "opticaldiscdrive")
                .font(.title2)
                .foregroundStyle(model.drive == nil ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.drive?.name ?? "No burner connected").font(.headline)
                Text(mediaDescription).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Eject") { model.eject() }
                .disabled(model.insertedMedia == nil || model.runner.isRunning)
        }
        .padding(12)
    }

    private var mediaDescription: String {
        guard model.drive != nil else { return "Connect a Blu-ray burner." }
        guard let media = model.insertedMedia else { return "No disc inserted" }
        var parts = [media.typeName, media.isBlank ? "blank" : "not blank"]
        if let free = media.freeBytes, media.isBlank { parts.append("\(ByteFormat.gib(free)) free") }
        return parts.joined(separator: " · ")
    }
}
