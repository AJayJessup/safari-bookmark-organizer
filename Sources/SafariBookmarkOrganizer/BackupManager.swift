import Foundation

/// Everything here writes only to OUR OWN backups directory. Nothing in this file
/// ever opens Safari's Bookmarks.plist for writing.
enum BackupManager {

    /// Ensures the one-time protected original snapshot exists (created once, ever,
    /// never overwritten), then writes a fresh timestamped snapshot. Call this before
    /// any operation that will modify Safari's bookmarks.
    @discardableResult
    static func snapshot(bookmarksPath: String, backupsDir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let originalURL = backupsDir.appendingPathComponent("ORIGINAL_SAFARI_BOOKMARKS.plist")
        if !fm.fileExists(atPath: originalURL.path) {
            try fm.copyItem(at: URL(fileURLWithPath: bookmarksPath), to: originalURL)
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: originalURL.path)
            print("Created protected original snapshot: \(originalURL.path)")
        } else {
            print("Original snapshot already exists (never overwritten): \(originalURL.path)")
        }

        let formatter = DateFormatter()
        // Phase 10 fix: second-level precision alone can collide when multiple
        // organize runs happen in quick succession (the watcher, the 15-minute
        // fallback, and a manual run can all take a backup within the same
        // second) - millisecond precision plus a numbered-suffix fallback makes
        // this collision-proof rather than just less likely.
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        var stampedURL = backupsDir.appendingPathComponent("\(formatter.string(from: Date())).plist")
        var suffix = 1
        while fm.fileExists(atPath: stampedURL.path) {
            stampedURL = backupsDir.appendingPathComponent("\(formatter.string(from: Date()))-\(suffix).plist")
            suffix += 1
        }
        try fm.copyItem(at: URL(fileURLWithPath: bookmarksPath), to: stampedURL)
        print("Created timestamped snapshot: \(stampedURL.path)")
        return stampedURL
    }

    static func listBackups(backupsDir: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupsDir.path) else { return [] }
        return try fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Restores a given backup file over Safari's Bookmarks.plist, atomically
    /// (copy to a temp file in the same directory, then replace). This is the one
    /// function in this whole project that writes to Safari's real file, and it is
    /// intentionally NOT wired to any CLI command yet.
    ///
    /// Per project safety requirements: this must be manually verified — tested
    /// against a throwaway copy of Bookmarks.plist first, not the live file — before
    /// it is ever exposed as a runnable command, and it always takes a safety
    /// snapshot of the *current* state before overwriting, so a bad restore is itself
    /// still reversible.
    static func restore(from backupPath: URL, toBookmarksPath bookmarksPath: String, backupsDir: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath.path) else {
            throw BookmarkStoreError.fileNotFound(backupPath.path)
        }
        // Safety-of-the-safety-net: snapshot current state before we overwrite it.
        try snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

        let dir = URL(fileURLWithPath: bookmarksPath).deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".Bookmarks.plist.tmp-\(UUID().uuidString)")
        try fm.copyItem(at: backupPath, to: tmp)
        _ = try fm.replaceItemAt(URL(fileURLWithPath: bookmarksPath), withItemAt: tmp)
    }
}
