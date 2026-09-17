import Foundation

let phase10AutoTestTitle = "ZZZ Safari Organizer Phase10 Auto Test — safe to delete"
let phase10AutoTestURL = "https://onlinepngtools.com/change-png-color"

let phase10ManualTestTitle = "ZZZ Safari Organizer Phase10 Manual Placement Test — safe to delete"
let phase10ManualTestURL = "https://example.com/phase10-manual-placement-test"

/// Adds one disposable bookmark, unfiled, reusing the exact title/url already
/// validated in Phase 8 to classify confidently into "Solve" - for testing that the
/// watcher/fallback automatically classify and move a genuinely new bookmark with no
/// Terminal command involved after this one.
func runPhase10AutoTestSetup(bookmarksPath: String, backupsDir: URL) throws {
    print("Taking a backup before adding the test bookmark")
    try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    let uuid = try BookmarkWriter.addBookmark(title: phase10AutoTestTitle, url: phase10AutoTestURL, path: bookmarksPath)
    print("Added test bookmark, unfiled:")
    print("  uuid:  \(uuid)")
    print("  title: \(phase10AutoTestTitle)")
    print("  url:   \(phase10AutoTestURL)")
    print("")
    print("This should classify confidently into \"Solve\". Don't run organize manually - let the watcher (or fallback) pick it up on its own.")
}

/// Adds one disposable bookmark, then immediately moves it into "Learn" - simulating
/// you manually filing a brand-new bookmark into a category folder yourself, before
/// the organizer ever processes it. Requirement 10: the organizer must leave this
/// exactly where it is, never reclassify it elsewhere.
func runPhase10ManualPlacementSetup(bookmarksPath: String, backupsDir: URL) throws {
    print("Taking a backup before adding the test bookmark")
    try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    let uuid = try BookmarkWriter.addBookmark(title: phase10ManualTestTitle, url: phase10ManualTestURL, path: bookmarksPath)
    try BookmarkWriter.moveBookmark(uuid: uuid, toFolderNamed: "Learn", path: bookmarksPath)

    let root = try BookmarkStore.readRoot(path: bookmarksPath)
    let flat = BookmarkStore.flatten(root: root)
    guard let placed = flat.first(where: { $0.uuid == uuid }) else {
        print("Something went wrong - bookmark not found after placing it. Nothing else changed.")
        return
    }
    print("Added test bookmark and manually placed it into \"Learn\":")
    print("  uuid:        \(uuid)")
    print("  title:       \(phase10ManualTestTitle)")
    print("  url:         \(phase10ManualTestURL)")
    print("  folder path: \(placed.folderPath)")
    print("")
    print("This is a genuinely new UUID already sitting in a category folder before the organizer runs. It should stay exactly here - logged as user_placed - never reclassified.")
}
