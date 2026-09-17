import Foundation

/// Phase 7: establishing and checking the "what's new" checkpoint. Both functions
/// are read-only against Safari's Bookmarks.plist - neither one ever writes to it.
/// Only the checkpoint file (KnownBookmarksStore) is written here.

/// Records every bookmark/folder UUID currently in Safari as "known," so none of
/// your existing ~32 bookmarks get treated as new. Run this once before the first
/// detect-new, and never automatically classifies or reorganizes anything.
func runBaseline(bookmarksPath: String, statePath: String) throws {
    print("Reading current Safari bookmarks (read-only)...")
    let root = try BookmarkStore.readRoot(path: bookmarksPath)
    let uuids = BookmarkStore.allUUIDs(root: root)
    print("Found \(uuids.count) bookmark/folder UUIDs (leaves + folders).")

    let url = try KnownBookmarksStore.save(uuids, to: statePath)
    print("Baseline written to \(url.path)")
    print("These \(uuids.count) items are now considered already-known.")
    print("Nothing was classified or moved. detect-new will only report items added to Safari after this point.")
}

/// Compares the current tree against the checkpoint and reports any leaf bookmark
/// whose UUID isn't in it yet. Does NOT update the checkpoint - a bookmark reported
/// here will be reported again on the next run, until a later classification/
/// processing step (Phase 8) explicitly advances the checkpoint.
func runDetectNew(bookmarksPath: String, statePath: String) throws {
    guard let known = try KnownBookmarksStore.loadIfExists(from: statePath) else {
        print("No baseline found at \(statePath).")
        print("Run `baseline` first, so your current bookmarks aren't all reported as new the first time.")
        return
    }

    let root = try BookmarkStore.readRoot(path: bookmarksPath)
    let flat = BookmarkStore.flatten(root: root)

    let newOnes = flat.filter { !known.contains($0.uuid) }

    if newOnes.isEmpty {
        print("No new bookmarks since the last checkpoint (\(known.count) known items).")
        return
    }

    print("\(newOnes.count) new bookmark(s) found:")
    for b in newOnes {
        let folder = b.folderPath.isEmpty ? "(top level)" : b.folderPath.joined(separator: " / ")
        print("- \(b.title)")
        print("    url:    \(b.url)")
        print("    folder: \(folder)")
        print("    uuid:   \(b.uuid)")
    }
    print("")
    print("Not marked as seen - re-running detect-new will report these again until they're processed (Phase 8).")
}
