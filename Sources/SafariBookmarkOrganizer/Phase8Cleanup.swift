import Foundation

/// Deletes the synthetic Phase 8 test bookmark and verifies the tree afterward.
/// Approved by Amber: delete this one bookmark only, verify by UUID (per her
/// clarification that title/url are never assumed unique - identity is always
/// WebBookmarkUUID), and leave the checkpoint and audit log untouched. The
/// organize_log.jsonl entry recording this bookmark's earlier successful move is a
/// historical record, not something this cleanup revises or removes.
func runPhase8Cleanup(bookmarksPath: String, backupsDir: URL) throws {
    print("[1/5] Taking a fresh timestamped backup before any write")
    try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)
    print("")

    print("[2/5] Locating the synthetic test bookmark")
    var root = try BookmarkStore.readRoot(path: bookmarksPath)
    var flat = BookmarkStore.flatten(root: root)
    let matches = flat.filter { $0.title == phase8TestTitle && $0.url == phase8TestURL }
    print("      found \(matches.count) matching bookmark(s)  (expect 1)")
    guard matches.count == 1, let target = matches.first else {
        print("      ABORTING - expected exactly one match, found \(matches.count). Not deleting anything.")
        return
    }
    let uuid = target.uuid
    print("      uuid = \(uuid), folder path = \(target.folderPath)  (expect [\"Solve\"])")

    let othersBefore = Dictionary(uniqueKeysWithValues: flat.filter { $0.uuid != uuid }.map { ($0.uuid, $0.folderPath) })
    let originalTotal = flat.count
    print("      total bookmarks before delete: \(originalTotal)")
    print("")

    print("[3/5] Deleting it")
    try BookmarkWriter.deleteBookmark(uuid: uuid, path: bookmarksPath)
    print("      delete complete")
    print("")

    print("[4/5] Verifying the plist afterward")
    root = try BookmarkStore.readRoot(path: bookmarksPath)
    flat = BookmarkStore.flatten(root: root)

    let stillPresent = flat.contains(where: { $0.uuid == uuid })
    print("      uuid \(uuid) still present anywhere: \(stillPresent)  (expect false)")

    let stillInSolve = flat.contains(where: { $0.uuid == uuid && $0.folderPath == ["Solve"] })
    print("      still in Solve: \(stillInSolve)  (expect false)")

    let othersAfter = Dictionary(uniqueKeysWithValues: flat.map { ($0.uuid, $0.folderPath) })
    var unchanged = true
    var missing: [String] = []
    for (u, pathBefore) in othersBefore {
        if let pathAfter = othersAfter[u] {
            if pathAfter != pathBefore {
                unchanged = false
                print("      CHANGED (should not have): \(u) was \(pathBefore) now \(pathAfter)")
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

    print("")
    print("[5/5] Done - checkpoint (known_bookmarks.json) and audit log (organize_log.jsonl) were not touched by this cleanup")

    let allGood = !stillPresent && !stillInSolve && unchanged && missing.isEmpty && flat.count == originalTotal - 1
    print("")
    print(allGood ? "=== PASS ===" : "=== FAIL - see details above ===")
}
