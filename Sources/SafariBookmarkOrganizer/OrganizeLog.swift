import Foundation

enum OrganizeLogError: Error, CustomStringConvertible {
    case encodingFailed

    var description: String { "Could not encode audit log entry as UTF-8" }
}

/// One line per bookmark per `organize` run: what the organizer decided and why.
/// Lives alongside the checkpoint, outside the Git repo (user-local runtime data,
/// not project source) - see KnownBookmarksStore.defaultStatePath for the same
/// reasoning.
struct OrganizeLogEntry: Codable {
    let timestamp: Date
    let mode: String              // "dry-run" or "live"
    let uuid: String
    let title: String
    let url: String
    let category: String?
    let confidence: Double?
    let classifierReason: String?
    let needsReview: Bool?
    let decision: String          // "organized", "review", "failed", "user_resolved",
                                   // "user_skipped", or "user_placed"
    let destinationFolder: String?
    let outcome: String           // human-readable detail: why this decision, or the error
    // Phase 10 addition. Optional so log lines written before this field existed
    // still decode correctly - readAll() must never break on old audit history.
    // "manual" (CLI, including review resolve), "watch" (FSEvents-triggered),
    // or "fallback" (15-minute LaunchAgent safety net).
    let trigger: String?
}

enum OrganizeLog {
    /// ~/.safari-organizer/state/organize_log.jsonl
    static var defaultLogPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".safari-organizer/state/organize_log.jsonl").path
    }

    static func append(_ entry: OrganizeLogEntry, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        guard var line = String(data: data, encoding: .utf8) else {
            throw OrganizeLogError.encodingFailed
        }
        line += "\n"
        let lineData = line.data(using: .utf8)!

        if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(lineData)
        } else {
            try lineData.write(to: URL(fileURLWithPath: path))
        }
    }
    /// Reads every entry ever appended, in file (chronological) order. Malformed
    /// lines are skipped rather than failing the whole read - this is an audit log,
    /// not a source of truth Safari or the checkpoint depend on.
    static func readAll(from path: String) throws -> [OrganizeLogEntry] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var entries: [OrganizeLogEntry] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else { continue }
            if let entry = try? decoder.decode(OrganizeLogEntry.self, from: data) {
                entries.append(entry)
            }
        }
        return entries
    }
}
