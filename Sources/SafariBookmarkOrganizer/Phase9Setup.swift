import Foundation

/// Two disposable synthetic bookmarks, each deliberately ambiguous between Consume
/// and Learn - the configured tie-break pair - so the classifier's own tie-break
/// rule reliably sets needs_review=true and organize routes them to review. Left
/// unfiled, exactly like phase8-test-setup, so `organize` has real review-bound
/// bookmarks to test resolution against.
let phase9TestATitle = "Crash Course World History \u{2014} full episodes"
let phase9TestAURL = "https://example.com/crash-course-world-history"

let phase9TestBTitle = "Language Learning Podcast \u{2014} daily Spanish episode"
let phase9TestBURL = "https://example.com/daily-spanish-podcast"

func runPhase9SetupTestBookmarks(bookmarksPath: String, backupsDir: URL) throws {
    print("Taking a fresh timestamped backup before any write")
    try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)
    print("")

    for (title, url) in [(phase9TestATitle, phase9TestAURL), (phase9TestBTitle, phase9TestBURL)] {
        let preCount = BookmarkWriter.countLeaves(
            in: try BookmarkStore.readRoot(path: bookmarksPath),
            title: title, url: url
        )
        guard preCount == 0 else {
            print("SKIPPING \"\(title)\" - already exists (\(preCount)).")
            continue
        }
        let uuid = try BookmarkWriter.addBookmark(title: title, url: url, path: bookmarksPath)
        print("Added: \"\(title)\"")
        print("  uuid: \(uuid)")
        print("  url:  \(url)")
        print("  left UNFILED at the top level")
        print("")
    }
}
