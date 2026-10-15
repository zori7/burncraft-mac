import Foundation

/// Keeps the system awake while `body` runs (the app's equivalent of `caffeinate -i`).
public func withSleepPrevented<T>(
    reason: String,
    _ body: () async throws -> T
) async rethrows -> T {
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .userInitiated], reason: reason)
    defer { ProcessInfo.processInfo.endActivity(activity) }
    return try await body()
}
