import Foundation

let phase6TestTitle = "ZZZ Safari Organizer Test — safe to delete"
let phase6TestURL = "https://example.com/organizer-test"
let phase6DestFolder = "Play"

func runPhase6Test(bookmarksPath: String, backupsDir: URL) throws {
    print("[1/6] Taking a fresh timestamped backup before any write")
    try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)
    print("")

    print("[2/6] Pre-check: confirming the test bookmark doesn't already exist")
    var root = try BookmarkStore.readRoot(path: bookmarksPath)
    let preCount = BookmarkWriter.countLeaves(in: root, title: phase6TestTitle, url: phase6TestURL)
    print("      existing count: \(preCount)")
    guard preCount == 0 else {
        print("      ABORTING - test bookmark already exists, not touching anything further.")
        return
    }
    let originalFlat = BookmarkStore.flatten(root: root)
    let originalTotal = originalFlat.count
    print("      total real bookmarks in tree right now: \(originalTotal)")
    print("")

    print("[3/6] Creating the synthetic test bookmark at the top level")
    let uuid = try BookmarkWriter.addBookmark(title: phase6TestTitle, url: phase6TestURL, path: bookmarksPath)
    print("      created, uuid = \(uuid)")

    root = try BookmarkStore.readRoot(path: bookmarksPath)
    let afterAddCount = BookmarkWriter.countLeaves(in: root, title: phase6TestTitle, url: phase6TestURL)
    let afterAddFlat = BookmarkStore.flatten(root: root)
    let createdEntry = afterAddFlat.first(where: { $0.uuid == uuid })
    print("      count after create: \(afterAddCount)  (expect 1)")
    print("      folder path after create: \(createdEntry?.folderPath ?? ["<not found>"])  (expect [] - top level)")
    guard afterAddCount == 1, createdEntry?.folderPath.isEmpty == true else {
        print("      ABORTING - creation did not verify cleanly.")
        return
    }
    print("")

    print("[4/6] Moving it into \"\(phase6DestFolder)\"")
    // Snapshot every OTHER bookmark's folder path before the move, to prove nothing
    // else changes.
    let othersBefore = Dictionary(uniqueKeysWithValues: afterAddFlat.filter { $0.uuid != uuid }.map { ($0.uuid, $0.folderPath) })
    try BookmarkWriter.moveBookmark(uuid: uuid, toFolderNamed: phase6DestFolder, path: bookmarksPath)
    print("      move complete")
    print("")

    print("[5/6] Verifying the plist afterward")
    root = try BookmarkStore.readRoot(path: bookmarksPath)
    let finalFlat = BookmarkStore.flatten(root: root)
    let finalCount = BookmarkWriter.countLeaves(in: root, title: phase6TestTitle, url: phase6TestURL)
    let movedEntry = finalFlat.first(where: { $0.uuid == uuid })

    print("      count of test bookmark: \(finalCount)  (expect 1 - not duplicated)")
    print("      its folder path now: \(movedEntry?.folderPath ?? ["<not found>"])  (expect [\"\(phase6DestFolder)\"])")

    let othersAfter = Dictionary(uniqueKeysWithValues: finalFlat.filter { $0.uuid != uuid }.map { ($0.uuid, $0.folderPath) })
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
    print("      total bookmarks now: \(finalFlat.count)  (expect \(originalTotal + 1))")

    let allGood = finalCount == 1
        && movedEntry?.folderPath == [phase6DestFolder]
        && unchanged
        && finalFlat.count == originalTotal + 1

    print("")
    print(allGood ? "=== PASS ===" : "=== FAIL - see details above ===")
    print("Test bookmark UUID: \(uuid)  (left in place - not cleaned up, per instructions)")
}
