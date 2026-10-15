// ImagingTests: disc image format, media registry and app naming.
//
// UDFImageFormatTests covers:
// - hdiutil arguments match the script exactly
//   (makehybrid -o … -udf -udf-version 2.50 -default-volume-name …).
// - Volume name validation: allowed characters, empty name, 30-character limit.
// - Default volume name is MEDIA_ARCHIVE_YYYYMMDD and is valid.
// - A failed hdiutil run deletes the partial image.
//
// RegistryTests covers:
// - Every media type points to registered image formats; media ids are unique.
// - Capacities and limits are consistent (limit <= capacity, 2048-byte blocks)
//   and speed choices are positive.
// - Defaults match the script: BD-R DL 50 GB at 4x.
//
// AppInfoTests covers:
// - Name, bundle id and log folder come from the generated app.config values,
//   so no name is hard-coded elsewhere.

@testable import BurnCore
import Foundation
import Testing

@Suite struct UDFImageFormatTests {
    let format = UDFImageFormat.udf250

    @Test func argumentsMatchTheScript() {
        let args = format.arguments(
            source: URL(filePath: "/src/My Folder"), volumeName: "DISC_01", output: URL(filePath: "/out/DISC_01.iso"))
        #expect(args == [
            "makehybrid", "-o", "/out/DISC_01.iso", "/src/My Folder",
            "-udf", "-udf-version", "2.50", "-default-volume-name", "DISC_01",
        ])
        #expect(format.id == "udf-2.50")
        #expect(format.fileExtension == "iso")
    }

    @Test(arguments: ["DISC_01", "MEDIA_ARCHIVE_20261015", "a-b", String(repeating: "X", count: 30)])
    func validVolumeNames(name: String) {
        #expect(format.validate(volumeName: name) == nil)
    }

    @Test(arguments: ["", "has space", "slash/name", "ünïcode", String(repeating: "X", count: 31)])
    func invalidVolumeNames(name: String) {
        #expect(format.validate(volumeName: name) != nil)
    }

    @Test func defaultVolumeNameFollowsScriptPattern() {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: 7))!
        #expect(AppInfo.defaultVolumeName(date: date) == "MEDIA_ARCHIVE_20260307")
        #expect(format.validate(volumeName: AppInfo.defaultVolumeName()) == nil)
    }

    @Test func failedBuildRemovesPartialImage() async throws {
        let dir = try TempDir()
        let output = dir.url.appending(path: "x.iso")
        try Data([1, 2, 3]).write(to: output)
        await #expect(throws: CommandError.self) {
            try await format.makeImage(
                source: dir.url, volumeName: "X", output: output,
                runner: FakeCommandRunner(failing: [UDFImageFormat.hdiutil])) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

@Suite struct RegistryTests {
    @Test func mediaReferenceRegisteredFormats() {
        for media in MediaType.all {
            #expect(!ImageFormats.formats(for: media).isEmpty, "\(media.id) has no registered image format")
            for id in media.imageFormatIDs { #expect(ImageFormats.format(id: id) != nil) }
        }
    }

    @Test func mediaIDsAreUnique() {
        #expect(Set(MediaType.all.map(\.id)).count == MediaType.all.count)
    }

    @Test(arguments: MediaType.all)
    func capacitiesAreSane(media: MediaType) {
        #expect(media.recommendedLimitBytes > 0)
        #expect(media.recommendedLimitBytes <= media.capacityBytes)
        #expect(media.capacityBytes % 2048 == 0)
        #expect(media.speedChoices.allSatisfy { $0 > 0 })
    }

    @Test func defaultsMatchTheScript() {
        #expect(MediaType.default == .bdr50)
        #expect(AppInfo.defaultBurnSpeed == 4)
        #expect(MediaType.bdr50.speedFactor(forKBps: MediaType.bdr50.speedKBps(forFactor: 4)) == 4)
    }
}

@Suite struct AppInfoTests {
    @Test func namesComeFromGeneratedConfig() {
        // Tests don't run from an .app bundle, so the generated constants apply.
        #expect(AppInfo.name == AppConfig.name)
        #expect(AppInfo.bundleID == AppConfig.bundleID)
        #expect(AppInfo.bundleID.hasPrefix("com."))
        #expect(AppInfo.logDirectory.lastPathComponent == AppInfo.name)
        #expect(AppInfo.logDirectory.deletingLastPathComponent().path.hasSuffix("Library/Logs"))
    }
}
