import Foundation

/// Plain-text operational log for the watcher/fallback (Phase 10) - separate from
/// the structured per-bookmark JSONL audit log in OrganizeLog.swift. This is for
/// "what was the watcher doing", not "what did the organizer decide about bookmark X".
enum WatchLog {
    /// ~/.safari-organizer/state/watch.log
    static var path: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".safari-organizer/state/watch.log").path
    }

    static func append(_ message: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func lastLines(_ n: Int) -> [String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(n))
    }
}
