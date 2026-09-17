import Foundation

/// Deletes the two synthetic Phase 9 test bookmarks by their exact UUIDs (never by
/// title/URL, per Amber's instruction) and verifies the tree afterward. Leaves the
/// checkpoint (known_bookmarks.json) and audit log (organize_log.jsonl) completely
/// untouched - including the historical test-fixture entries, which stay as a
/// permanent record of this test, not something this cleanup revises.
let phase9CleanupUUIDs = [
    "C73610AF-D964-4847-A825-D5C3F08A9F50", // "Crash Course World History — full episodes"
    "FFEA451A-43AC-4C2F-AE7F-08FF79628657", // "Language Learning Podcast — daily Spanish episode"
]

func runPhase9Cleanup(bookmarksPath: String, backupsDir: URL) throws {
    print("[1/5] Taking a fresh timestamped backup before any write")
    try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)
    print("")

    print("[2/5] Locating both test bookmarks by exact UUID")
    var root = try BookmarkStore.readRoot(path: bookmarksPath)
    var flat = BookmarkStore.flatten(root: root)
    let preFolderNames = BookmarkStore.topLevelFolderNames(root: root)

    var targets: [BookmarkStore.FlatBookmark] = []
    for uuid in phase9CleanupUUIDs {
        guard let found = flat.first(where: { $0.uuid == uuid }) else {
            print("      ABORTING - uuid \(uuid) not found. Not deleting anything.")
            return
        }
        print("      found \(uuid): \"\(found.title)\", folder path = \(found.folderPath)")
        targets.append(found)
    }

    let targetUUIDs = Set(targets.map { $0.uuid })
    let othersBefore = Dictionary(uniqueKeysWithValues: flat.filter { !targetUUIDs.contains($0.uuid) }.map { ($0.uuid, $0.folderPath) })
    let originalTotal = flat.count
    print("      total bookmarks before delete: \(originalTotal)")
    print("")

    print("[3/5] Deleting both, one at a time, by UUID")
    for uuid in phase9CleanupUUIDs {
        try BookmarkWriter.deleteBookmark(uuid: uuid, path: bookmarksPath)
        print("      deleted \(uuid)")
    }
    print("")

    print("[4/5] Verifying the plist afterward")
    root = try BookmarkStore.readRoot(path: bookmarksPath)
    flat = BookmarkStore.flatten(root: root)
    let postFolderNames = BookmarkStore.topLevelFolderNames(root: root)

    var allGood = true

    for uuid in phase9CleanupUUIDs {
        let stillPresent = flat.contains(where: { $0.uuid == uuid })
        print("      uuid \(uuid) still present anywhere: \(stillPresent)  (expect false)")
        if stillPresent { allGood = false }
    }

    let stillInLearnOrTop = flat.contains(where: {
        targetUUIDs.contains($0.uuid) && ($0.folderPath == ["Learn"] || $0.folderPath.isEmpty)
    })
    print("      either target still in Learn or at top level: \(stillInLearnOrTop)  (expect false)")
    if stillInLearnOrTop { allGood = false }

    print("      total bookmarks now: \(flat.count)  (expect \(originalTotal - phase9CleanupUUIDs.count))")
    if flat.count != originalTotal - phase9CleanupUUIDs.count { allGood = false }

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
    if !unchanged { allGood = false }

    let foldersUnchanged = postFolderNames == preFolderNames
    print("      top-level folder structure unchanged: \(foldersUnchanged)")
    if !foldersUnchanged { allGood = false }

    print("")
    print("[5/5] Done - checkpoint (known_bookmarks.json) and audit log (organize_log.jsonl), including historical test entries, were not touched by this cleanup")

    print("")
    print(allGood ? "=== PASS ===" : "=== FAIL - see details above ===")
}
