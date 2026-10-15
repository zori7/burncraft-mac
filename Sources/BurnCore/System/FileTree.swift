import Foundation

/// File-system walks shared by the size check, cleaner and checksum steps.
public enum FileTree {
    public struct Entry: Sendable, Equatable {
        /// Path relative to the root, without a leading "./".
        public let relativePath: String
        public let size: Int64
    }

    /// Regular files (no symlinks), sorted by path, skipping files whose name starts
    /// with "." or matches `excludedNames`. Mirrors `find . -type f ! -name ".*"`.
    public static func regularFiles(in root: URL, excludingNames excludedNames: Set<String> = []) throws -> [Entry] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var entries: [Entry] = []
        while let relative = enumerator.nextObject() as? String {
            guard let attributes = enumerator.fileAttributes,
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let name = (relative as NSString).lastPathComponent
            if name.hasPrefix(".") || excludedNames.contains(name) { continue }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(Entry(relativePath: relative, size: size))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    /// On-disk allocated size of everything under `root` (like `du -sk`, in bytes).
    public static func allocatedSize(of root: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Paths of all files with the given name under `root`.
    public static func files(named name: String, in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var result: [URL] = []
        while let relative = enumerator.nextObject() as? String {
            if (relative as NSString).lastPathComponent == name {
                result.append(root.appending(path: relative, directoryHint: .notDirectory))
            }
        }
        return result
    }
}

public enum ByteFormat {
    public static func gib(_ bytes: Int64) -> String {
        String(format: "%.2f GiB", Double(bytes) / Double(MediaType.gib))
    }

    public static func short(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
