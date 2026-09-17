import Foundation

enum BookmarkWriterError: Error, CustomStringConvertible {
    case folderNotFound(String)
    case bookmarkNotFound(String)

    var description: String {
        switch self {
        case .folderNotFound(let name): return "No top-level folder named \"\(name)\" found"
        case .bookmarkNotFound(let uuid): return "No bookmark with UUID \(uuid) found"
        }
    }
}

/// The only file in this project that writes to Safari's actual Bookmarks.plist.
/// Every write here is atomic (temp file in the same directory, then rename) so
/// Safari never sees a half-written file, and every public function only ever
/// touches the one node it's told to - nothing else in the tree is altered.
enum BookmarkWriter {

    private static func writeRoot(_ root: [String: Any], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".Bookmarks.plist.tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: tmp)
    }

    /// How many leaf bookmarks anywhere in the tree have exactly this title+url.
    static func countLeaves(in root: [String: Any], title: String, url: String) -> Int {
        var count = 0
        func walk(_ node: [String: Any]) {
            let type = node["WebBookmarkType"] as? String ?? ""
            if type == "WebBookmarkTypeLeaf" {
                let t = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                let u = node["URLString"] as? String
                if t == title && u == url { count += 1 }
            } else if type == "WebBookmarkTypeList" {
                for child in (node["Children"] as? [[String: Any]] ?? []) { walk(child) }
            }
        }
        for child in (root["Children"] as? [[String: Any]] ?? []) { walk(child) }
        return count
    }

    /// Adds one new leaf bookmark to the ROOT's top-level Children - i.e. unfoldered,
    /// exactly like a brand-new bookmark Safari hasn't filed anywhere yet.
    @discardableResult
    static func addBookmark(title: String, url: String, path: String) throws -> String {
        var root = try BookmarkStore.readRoot(path: path)
        var topChildren = root["Children"] as? [[String: Any]] ?? []

        let uuid = UUID().uuidString
        let newNode: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "WebBookmarkUUID": uuid,
            "URLString": url,
            "URIDictionary": ["title": title],
        ]
        topChildren.append(newNode)
        root["Children"] = topChildren
        try writeRoot(root, to: path)
        return uuid
    }

    /// Finds the node with this UUID anywhere in the tree, removes it from its
    /// current parent's Children (whatever depth it's at), and appends the SAME
    /// node - all fields preserved unchanged - into the top-level folder named
    /// `folderName`. Every other node's contents and position are left untouched.
    static func moveBookmark(uuid: String, toFolderNamed folderName: String, path: String) throws {
        var root = try BookmarkStore.readRoot(path: path)
        var foundNode: [String: Any]?

        func removeFromChildren(_ children: inout [[String: Any]]) {
            for i in children.indices {
                let type = children[i]["WebBookmarkType"] as? String ?? ""
                if type == "WebBookmarkTypeLeaf", children[i]["WebBookmarkUUID"] as? String == uuid {
                    foundNode = children.remove(at: i)
                    return
                } else if type == "WebBookmarkTypeList" {
                    var sub = children[i]["Children"] as? [[String: Any]] ?? []
                    removeFromChildren(&sub)
                    children[i]["Children"] = sub
                    if foundNode != nil { return }
                }
            }
        }

        var topChildren = root["Children"] as? [[String: Any]] ?? []
        removeFromChildren(&topChildren)
        root["Children"] = topChildren

        guard let node = foundNode else {
            throw BookmarkWriterError.bookmarkNotFound(uuid)
        }

        topChildren = root["Children"] as? [[String: Any]] ?? []
        guard let destIndex = topChildren.firstIndex(where: {
            ($0["WebBookmarkType"] as? String) == "WebBookmarkTypeList" && ($0["Title"] as? String) == folderName
        }) else {
            throw BookmarkWriterError.folderNotFound(folderName)
        }

        var destChildren = topChildren[destIndex]["Children"] as? [[String: Any]] ?? []
        destChildren.append(node)
        topChildren[destIndex]["Children"] = destChildren
        root["Children"] = topChildren

        try writeRoot(root, to: path)
    }
    /// Finds the node with this UUID anywhere in the tree and removes it entirely -
    /// it is not reinserted anywhere. Every other node's contents and position are
    /// left untouched.
    static func deleteBookmark(uuid: String, path: String) throws {
        var root = try BookmarkStore.readRoot(path: path)
        var foundNode: [String: Any]?

        func removeFromChildren(_ children: inout [[String: Any]]) {
            for i in children.indices {
                let type = children[i]["WebBookmarkType"] as? String ?? ""
                if type == "WebBookmarkTypeLeaf", children[i]["WebBookmarkUUID"] as? String == uuid {
                    foundNode = children.remove(at: i)
                    return
                } else if type == "WebBookmarkTypeList" {
                    var sub = children[i]["Children"] as? [[String: Any]] ?? []
                    removeFromChildren(&sub)
                    children[i]["Children"] = sub
                    if foundNode != nil { return }
                }
            }
        }

        var topChildren = root["Children"] as? [[String: Any]] ?? []
        removeFromChildren(&topChildren)
        root["Children"] = topChildren

        guard foundNode != nil else {
            throw BookmarkWriterError.bookmarkNotFound(uuid)
        }

        try writeRoot(root, to: path)
    }
}
