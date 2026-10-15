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
                HStack(spacing: 6) {
                    Text(model.drive?.name ?? "No burner connected").font(.headline)
                    if model.drive?.isSimulated == true {
                        Text("SIMULATED")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .foregroundStyle(.white)
                            .background(.orange, in: Capsule())
                            .help("No real disc is written. Turn off with: defaults delete \(AppInfo.bundleID) \(AppInfo.simulatedDriveDefaultsKey)")
                    }
                }
                Text(mediaDescription).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.drive?.isSimulated == true ? "Eject / New Disc" : "Eject") { model.eject() }
                .disabled(model.insertedMedia == nil || model.isBurning)
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
