import Foundation

enum VerifiedMoveError: Error, CustomStringConvertible {
    case destinationFolderNotFound(String)
    case bookmarkNotFound(String)

    var description: String {
        switch self {
        case .destinationFolderNotFound(let name):
            return "destination folder \"\(name)\" not found in Safari - left unprocessed"
        case .bookmarkNotFound(let uuid):
            return "bookmark with uuid \(uuid) not found in Safari - left unprocessed"
        }
    }
}

struct VerifiedMoveResult {
    let success: Bool
    let failures: [String]
}

/// Shared by `organize` and `review resolve --category`: moves one bookmark by UUID
/// into a top-level Safari folder and verifies the result strictly by UUID - never
/// by title/URL, which Safari never guarantees unique. Does not touch any
/// checkpoint; callers decide when, and whether, to advance it.
enum VerifiedMove {
    static func moveAndVerify(uuid: String, toFolderNamed safariFolder: String, bookmarksPath: String) throws -> VerifiedMoveResult {
        let preRoot = try BookmarkStore.readRoot(path: bookmarksPath)
        let preFlat = BookmarkStore.flatten(root: preRoot)
        let preFolderNames = BookmarkStore.topLevelFolderNames(root: preRoot)

        guard preFolderNames.contains(safariFolder) else {
            throw VerifiedMoveError.destinationFolderNotFound(safariFolder)
        }
        guard let before = preFlat.first(where: { $0.uuid == uuid }) else {
            throw VerifiedMoveError.bookmarkNotFound(uuid)
        }

        let othersBefore = Dictionary(uniqueKeysWithValues: preFlat.filter { $0.uuid != uuid }.map { ($0.uuid, $0.folderPath) })
        let totalBefore = preFlat.count

        try BookmarkWriter.moveBookmark(uuid: uuid, toFolderNamed: safariFolder, path: bookmarksPath)

        let postRoot = try BookmarkStore.readRoot(path: bookmarksPath)
        let postFlat = BookmarkStore.flatten(root: postRoot)
        let postFolderNames = BookmarkStore.topLevelFolderNames(root: postRoot)

        let matches = postFlat.filter { $0.uuid == uuid }
        var failures: [String] = []

        if matches.count != 1 {
            failures.append("expected exactly one bookmark with uuid \(uuid) after the move, found \(matches.count)")
        }
        let moved = matches.first
        if let moved, moved.folderPath != [safariFolder] {
            failures.append("folder path after move is \(moved.folderPath), expected [\"\(safariFolder)\"]")
        }
        if let moved, moved.title != before.title || moved.url != before.url {
            failures.append("title/url changed during move (before: \"\(before.title)\" / \(before.url), after: \"\(moved.title)\" / \(moved.url))")
        }
        if postFlat.count != totalBefore {
            failures.append("total leaf bookmark count changed: \(totalBefore) -> \(postFlat.count)")
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
                failures.append("another bookmark (\(u)) is missing after the move")
            }
        }

        return VerifiedMoveResult(success: failures.isEmpty, failures: failures)
    }
}
