import Foundation

enum KnownBookmarksStoreError: Error, CustomStringConvertible {
    case notBaselined(String)

    var description: String {
        switch self {
        case .notBaselined(let path):
            return "No baseline found at \(path). Run `baseline` first."
        }
    }
}

/// The Phase 7 checkpoint: which bookmark/folder UUIDs have already been accounted
/// for. This is NOT a copy of bookmark content and NOT a competing database - it is
/// just a set of UUIDs, used only to tell which items in Safari are genuinely new.
struct KnownBookmarksState: Codable {
    var knownUUIDs: [String]
    var lastUpdated: Date
}

/// Reads and writes the checkpoint file. Deliberately lives outside the project/Git
/// repo entirely, in a user-local app state directory - see defaultStatePath - so it
/// can never be accidentally committed or shared. It is runtime state specific to
/// this Mac, not project source.
enum KnownBookmarksStore {

    /// ~/.safari-organizer/state/known_bookmarks.json
    static var defaultStatePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".safari-organizer/state/known_bookmarks.json").path
    }

    static func load(from path: String) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: path) else {
            throw KnownBookmarksStoreError.notBaselined(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(KnownBookmarksState.self, from: data)
        return Set(state.knownUUIDs)
    }

    /// Like `load`, but returns nil instead of throwing when there's no baseline yet -
    /// for callers that want to give a friendly "run baseline first" message.
    static func loadIfExists(from path: String) throws -> Set<String>? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try load(from: path)
    }

    @discardableResult
    static func save(_ uuids: Set<String>, to path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let state = KnownBookmarksState(knownUUIDs: uuids.sorted(), lastUpdated: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
        return url
    }
    /// Adds one UUID to the checkpoint and saves immediately. Used by `organize`
    /// only after a move has been verified - so a run that's interrupted partway
    /// through never loses credit for the bookmarks that already succeeded, and a
    /// bookmark that failed or was sent to review is never marked processed.
    static func markProcessed(uuid: String, statePath: String) throws {
        var current = try load(from: statePath)
        current.insert(uuid)
        try save(current, to: statePath)
    }
}
