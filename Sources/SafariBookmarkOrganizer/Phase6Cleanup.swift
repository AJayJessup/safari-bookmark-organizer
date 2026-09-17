import Foundation

/// Deletes the synthetic Phase 6 test bookmark and verifies the tree afterward.
/// Approved by Amber: delete `phase6TestTitle` / `phase6TestURL` only, then verify
/// (1) it no longer exists anywhere, (2) Play is back to its pre-test state,
/// (3) no other bookmark or folder changed.
func runPhase6Cleanup(bookmarksPath: String, backupsDir: URL) throws {
    print("[1/5] Taking a fresh timestamped backup before any write")
    try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)
    print("")

    print("[2/5] Locating the synthetic test bookmark")
    var root = try BookmarkStore.readRoot(path: bookmarksPath)
    var flat = BookmarkStore.flatten(root: root)
    let matches = flat.filter { $0.title == phase6TestTitle && $0.url == phase6TestURL }
    print("      found \(matches.count) matching bookmark(s)  (expect 1)")
    guard matches.count == 1, let target = matches.first else {
        print("      ABORTING - expected exactly one match, found \(matches.count). Not deleting anything.")
        return
    }
    print("      uuid = \(target.uuid), folder path = \(target.folderPath)  (expect [\"\(phase6DestFolder)\"])")

    // Snapshot every OTHER bookmark's folder path before the delete, to prove
    // nothing else changes.
    let othersBefore = Dictionary(uniqueKeysWithValues: flat.filter { $0.uuid != target.uuid }.map { ($0.uuid, $0.folderPath) })
    let originalTotal = flat.count
    print("      total bookmarks before delete: \(originalTotal)")
    print("")

    print("[3/5] Deleting it")
    try BookmarkWriter.deleteBookmark(uuid: target.uuid, path: bookmarksPath)
    print("      delete complete")
    print("")

    print("[4/5] Verifying the plist afterward")
    root = try BookmarkStore.readRoot(path: bookmarksPath)
    flat = BookmarkStore.flatten(root: root)
    let finalCount = BookmarkWriter.countLeaves(in: root, title: phase6TestTitle, url: phase6TestURL)
    print("      count of test bookmark anywhere in tree: \(finalCount)  (expect 0)")

    let othersAfter = Dictionary(uniqueKeysWithValues: flat.map { ($0.uuid, $0.folderPath) })
    var unchanged = true
    var missing: [String] = []
    for (u, path) in othersBefore {
        if let nowPath = othersAfter[u] {
            if nowPath != path {
                unchanged = false
                print("      CHANGED (should not have): \(u) was \(path) now \(nowPath)")
            }
        } else {
            missing.append(u)
            unchanged = false
        }
    }
    if !missing.isEmpty {
        print("      MISSING (should not be): \(missing)")
    }
    print("      every other bookmark's folder unchanged: \(unchanged)")
    print("      total bookmarks now: \(flat.count)  (expect \(originalTotal - 1))")

    let playCount = flat.filter { $0.folderPath == [phase6DestFolder] }.count
    print("      \"\(phase6DestFolder)\" folder bookmark count now: \(playCount)  (expect 0 - back to pre-test state)")

    print("")
    print("[5/5] Done")

    let allGood = finalCount == 0
        && unchanged
        && missing.isEmpty
        && flat.count == originalTotal - 1
        && playCount == 0

    print("")
    print(allGood ? "=== PASS ===" : "=== FAIL - see details above ===")
}
