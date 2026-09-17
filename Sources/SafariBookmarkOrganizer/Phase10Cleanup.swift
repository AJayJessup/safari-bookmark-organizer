import Foundation

/// Generic Phase 10 test-fixture cleanup: deletes bookmarks by EXACT UUID only,
/// never by title/URL - per project convention, title/URL are never a safe identity.
/// Verifies each requested UUID is gone, every other bookmark/folder is unchanged,
/// and does not touch the checkpoint or audit log (historical entries, including
/// test-fixture ones, are left exactly as every prior phase's cleanup has done).
func runPhase10Cleanup(uuids: [String], bookmarksPath: String, backupsDir: URL) throws {
    guard !uuids.isEmpty else {
        print("Usage: phase10-cleanup <uuid> [<uuid> ...]")
        return
    }

    let preRoot = try BookmarkStore.readRoot(path: bookmarksPath)
    let preFlat = BookmarkStore.flatten(root: preRoot)
    let preFolderNames = BookmarkStore.topLevelFolderNames(root: preRoot)
    let preTotal = preFlat.count

    let toDelete = uuids.filter { uuid in preFlat.contains(where: { $0.uuid == uuid }) }
    for uuid in uuids where !toDelete.contains(uuid) {
        print("uuid \(uuid) not found in Safari - skipping.")
    }
    guard !toDelete.isEmpty else {
        print("None of the given UUIDs were found. Nothing changed.")
        return
    }

    print("Taking a backup before deleting")
    try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    let othersBefore = Dictionary(uniqueKeysWithValues: preFlat.filter { !toDelete.contains($0.uuid) }.map { ($0.uuid, $0.folderPath) })

    for uuid in toDelete {
        try BookmarkWriter.deleteBookmark(uuid: uuid, path: bookmarksPath)
    }

    let postRoot = try BookmarkStore.readRoot(path: bookmarksPath)
    let postFlat = BookmarkStore.flatten(root: postRoot)
    let postFolderNames = BookmarkStore.topLevelFolderNames(root: postRoot)

    var failures: [String] = []
    for uuid in toDelete where postFlat.contains(where: { $0.uuid == uuid }) {
        failures.append("uuid \(uuid) still present after delete")
    }
    if postFlat.count != preTotal - toDelete.count {
        failures.append("total leaf count is \(postFlat.count), expected \(preTotal - toDelete.count)")
    }
    if postFolderNames != preFolderNames {
        failures.append("top-level folder structure changed")
    }
    for (u, pathBefore) in othersBefore {
        if let pathAfter = postFlat.first(where: { $0.uuid == u })?.folderPath {
            if pathAfter != pathBefore {
                failures.append("another bookmark (\(u)) moved: was \(pathBefore), now \(pathAfter)")
            }
        } else {
            failures.append("another bookmark (\(u)) is missing after cleanup")
        }
    }

    if failures.isEmpty {
        print("=== PASS ===")
        print("Deleted \(toDelete.count) bookmark(s): \(toDelete.joined(separator: ", "))")
        print("All other bookmarks and folders unchanged. Checkpoint and audit log untouched by this cleanup.")
    } else {
        print("=== FAIL ===")
        for f in failures { print("- \(f)") }
    }
}
