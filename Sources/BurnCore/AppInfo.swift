import Foundation

/// Runtime constants. UI, logs and notifications read names only from here.
/// Names come from app.config (via the generated `AppConfig`), or from the bundle's
/// Info.plist when running as a built .app.
public enum AppInfo {
    private static var appBundle: Bundle? {
        Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : nil
    }

    /// True when running from a real .app bundle (required for UserNotifications).
    public static var isBundled: Bool { appBundle != nil }

    public static var name: String {
        appBundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? AppConfig.name
    }

    public static var bundleID: String {
        appBundle?.bundleIdentifier ?? AppConfig.bundleID
    }

    public static var version: String {
        appBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppConfig.version
    }

    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }

    /// Hidden developer setting: use `SimulatedBurner` instead of a real drive.
    /// Turn on with `defaults write <bundle id> SimulatedDrive -bool YES`
    /// or launch with `--args -SimulatedDrive YES`.
    public static let simulatedDriveDefaultsKey = "SimulatedDrive"

    public static var isSimulatedDriveEnabled: Bool {
        UserDefaults.standard.bool(forKey: simulatedDriveDefaultsKey)
    }

    public static let defaultVolumePrefix = "MEDIA_ARCHIVE_"
    public static let defaultBurnSpeed = 4
    public static let mountTimeout: Duration = .seconds(300)

    /// `MEDIA_ARCHIVE_YYYYMMDD`, like make_archive.sh.
    public static func defaultVolumeName(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return defaultVolumePrefix + formatter.string(from: date)
    }
}
