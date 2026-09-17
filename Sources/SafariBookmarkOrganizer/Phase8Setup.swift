import Foundation

/// One-off helper: adds a single disposable synthetic bookmark, UNFILED (top level),
/// so the Phase 8 `organize` pipeline has something real to detect and classify.
/// Does not move or classify it - that's organize's job. Same disposable-naming
/// convention as the Phase 6 test bookmark, and just as safe to delete afterward.
let phase8TestTitle = "ZZZ Safari Organizer Phase8 Test \u{2014} safe to delete"
let phase8TestURL = "https://onlinepngtools.com/change-png-color"

func runPhase8SetupTestBookmark(bookmarksPath: String, backupsDir: URL) throws {
    print("Taking a fresh timestamped backup before any write")
    try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)
    print("")

    let preCount = BookmarkWriter.countLeaves(
        in: try BookmarkStore.readRoot(path: bookmarksPath),
        title: phase8TestTitle, url: phase8TestURL
    )
    guard preCount == 0 else {
        print("ABORTING - a bookmark with this exact title/url already exists (\(preCount)). Not adding another.")
        return
    }

    let uuid = try BookmarkWriter.addBookmark(title: phase8TestTitle, url: phase8TestURL, path: bookmarksPath)
    print("Added synthetic test bookmark, uuid = \(uuid)")
    print("  title: \(phase8TestTitle)")
    print("  url:   \(phase8TestURL)")
    print("  left UNFILED at the top level, on purpose - organize should find and classify it")

    let flat = BookmarkStore.flatten(root: try BookmarkStore.readRoot(path: bookmarksPath))
    if let entry = flat.first(where: { $0.uuid == uuid }), entry.folderPath.isEmpty {
        print("Verified: present at top level, not yet in any category folder.")
    } else {
        print("WARNING: could not verify the new bookmark's location as expected.")
    }
}
