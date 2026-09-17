import Foundation

enum BookmarkStoreError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidFormat(String)

    var description: String {
        switch self {
        case .fileNotFound(let p): return "File not found at \(p)"
        case .invalidFormat(let m): return "Invalid plist format: \(m)"
        }
    }
}

/// Reads Safari's Bookmarks.plist. Every function here is read-only: none of them
/// ever open the file for writing. Writing lives in BackupManager (writes only to our
/// own backups) and, later, in a dedicated writer that is not implemented yet.
enum BookmarkStore {

    /// Returns the raw root dictionary, preserving every key exactly as Safari wrote it.
    /// We deliberately keep this as [String: Any] rather than a strict Codable model,
    /// because sibling bookmark nodes carry different optional metadata (TopicRank,
    /// dateAdded, imageURL, previewText, ...) and a strict schema would silently drop
    /// fields we don't yet know about the moment we ever write a node back out.
    static func readRoot(path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw BookmarkStoreError.fileNotFound(path)
        }
        let data = try readDataWithRetry(path: path)
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw BookmarkStoreError.invalidFormat("root is not a dictionary")
        }
        return root
    }

    /// Phase 10: running under a background LaunchAgent has shown occasional
    /// transient "Operation not permitted" errors from macOS's privacy protection
    /// (TCC) - the SAME already-running, already-granted process intermittently
    /// denied and then allowed access to the same file moments later. This is a
    /// macOS quirk with unsigned standalone binaries under launchd, not a data
    /// problem, so a couple of retries a beat apart lets it resolve within the same
    /// run instead of requiring an entirely separate trigger. Read-only, so this
    /// never risks correctness - it only changes how patiently a read is attempted.
    private static func readDataWithRetry(path: String, attempts: Int = 3, delay: TimeInterval = 1.0) throws -> Data {
        var lastError: Error = BookmarkStoreError.invalidFormat("no read attempted")
        for attempt in 1...attempts {
            do {
                return try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                lastError = error
                if attempt < attempts {
                    Thread.sleep(forTimeInterval: delay)
                }
            }
        }
        throw lastError
    }

    /// Flattened view of every leaf bookmark in the tree, with its folder path, for
    /// convenience (diffing, printing, classification input). Read-only.
    struct FlatBookmark {
        let uuid: String
        let title: String
        let url: String
        let folderPath: [String]   // e.g. ["Solve"] or ["Solve", "SubfolderIfAny"]
    }

    static func flatten(root: [String: Any]) -> [FlatBookmark] {
        var results: [FlatBookmark] = []
        let topChildren = root["Children"] as? [[String: Any]] ?? []
        for child in topChildren {
            walk(child, path: [], into: &results)
        }
        return results
    }

    private static func walk(_ node: [String: Any], path: [String], into results: inout [FlatBookmark]) {
        let type = node["WebBookmarkType"] as? String ?? ""
        switch type {
        case "WebBookmarkTypeLeaf":
            let uuid = node["WebBookmarkUUID"] as? String ?? UUID().uuidString
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? "(untitled)"
            let url = node["URLString"] as? String ?? ""
            results.append(FlatBookmark(uuid: uuid, title: title, url: url, folderPath: path))
        case "WebBookmarkTypeList":
            let title = node["Title"] as? String ?? "(untitled folder)"
            let children = node["Children"] as? [[String: Any]] ?? []
            for child in children {
                walk(child, path: path + [title], into: &results)
            }
        default:
            break // WebBookmarkTypeProxy and anything else: not user bookmark content, skip.
        }
    }

    static func printTree(path: String) throws {
        let root = try readRoot(path: path)
        print("=== Safari Bookmarks: \(path) ===")
        let children = root["Children"] as? [[String: Any]] ?? []
        for child in children {
            printNode(child, depth: 0)
        }
    }

    private static func printNode(_ node: [String: Any], depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        let type = node["WebBookmarkType"] as? String ?? "?"
        let uuid = node["WebBookmarkUUID"] as? String ?? "(no uuid)"
        switch type {
        case "WebBookmarkTypeLeaf":
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? "(untitled)"
            let url = node["URLString"] as? String ?? "(no url)"
            print("\(indent)- [\(uuid)] \(title)  \u{2014}  \(url)")
        case "WebBookmarkTypeList":
            let title = node["Title"] as? String ?? "(untitled folder)"
            print("\(indent)+ [\(uuid)] \(title)/")
            let children = node["Children"] as? [[String: Any]] ?? []
            for child in children {
                printNode(child, depth: depth + 1)
            }
        default:
            let title = node["Title"] as? String ?? "(system node)"
            print("\(indent)? [\(uuid)] \(title) (type=\(type))")
        }
    }
    /// Every WebBookmarkUUID in the tree - leaves AND folders alike. Used by Phase 7's
    /// baseline checkpoint, which records folders as known too, not just bookmarks.
    static func allUUIDs(root: [String: Any]) -> Set<String> {
        var uuids: Set<String> = []
        func walk(_ node: [String: Any]) {
            if let uuid = node["WebBookmarkUUID"] as? String {
                uuids.insert(uuid)
            }
            let type = node["WebBookmarkType"] as? String ?? ""
            if type == "WebBookmarkTypeList" {
                for child in (node["Children"] as? [[String: Any]] ?? []) { walk(child) }
            }
        }
        for child in (root["Children"] as? [[String: Any]] ?? []) { walk(child) }
        return uuids
    }
    /// The Titles of every top-level folder (WebBookmarkTypeList) directly under
    /// root. Used to check a destination folder exists before attempting a move,
    /// and to confirm top-level folder structure is unchanged after one.
    static func topLevelFolderNames(root: [String: Any]) -> Set<String> {
        var names: Set<String> = []
        for child in (root["Children"] as? [[String: Any]] ?? []) {
            if (child["WebBookmarkType"] as? String) == "WebBookmarkTypeList",
               let title = child["Title"] as? String {
                names.insert(title)
            }
        }
        return names
    }
}
