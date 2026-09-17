import Foundation

/// Phase 9: resolving what `organize` sent to review. Nothing here ever
/// reclassifies a bookmark or lowers the confidence threshold - every resolution is
/// an explicit choice the user made, recorded as such (user_resolved / user_skipped),
/// distinct from the organizer's own automatic `organized` decisions.

struct PendingReviewItem {
    let uuid: String
    let title: String
    let url: String
    let category: String?
    let confidence: Double?
    let classifierReason: String?
    let flaggedReason: String
}

enum ReviewLog {
    /// Pending status comes from the audit history, never a separate flag: for each
    /// UUID, only its MOST RECENT log entry matters. If that entry's decision is
    /// "review", it's still pending. Any later "organized", "user_resolved",
    /// "user_skipped", or "failed" entry for the same UUID means it's no longer
    /// pending - so once something is resolved, it stops appearing here.
    static func pendingItems(logPath: String) throws -> [PendingReviewItem] {
        let entries = try OrganizeLog.readAll(from: logPath)

        var latestByUUID: [String: OrganizeLogEntry] = [:]
        for entry in entries {
            latestByUUID[entry.uuid] = entry // file is append-only chronological
        }

        return latestByUUID.values
            .filter { $0.decision == "review" }
            .sorted { $0.timestamp < $1.timestamp }
            .map { entry in
                PendingReviewItem(
                    uuid: entry.uuid, title: entry.title, url: entry.url,
                    category: entry.category, confidence: entry.confidence,
                    classifierReason: entry.classifierReason,
                    flaggedReason: entry.outcome
                )
            }
    }
}

func runReviewList(logPath: String) throws {
    let pending = try ReviewLog.pendingItems(logPath: logPath)

    if pending.isEmpty {
        print("No pending review items.")
        return
    }

    print("\(pending.count) pending review item(s):")
    print("")
    for item in pending {
        print("- \(item.title)")
        print("    uuid:              \(item.uuid)")
        print("    url:               \(item.url)")
        let conf = item.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
        print("    attempted category: \(item.category ?? "(none)")  (confidence \(conf))")
        print("    classifier reason: \(item.classifierReason ?? "(n/a)")")
        print("    flagged because:   \(item.flaggedReason)")
        print("")
    }
    print("Resolve one with:")
    print("  review resolve <uuid> --category \"CategoryName\" [--live]   (dry run without --live)")
    print("  review resolve <uuid> --skip")
}

/// User explicitly chose a category for a pending review item. Requires the
/// category to exist and be enabled, and (on a live run) the corresponding Safari
/// folder to already exist. Verifies exactly as `organize` does, by UUID, and only
/// advances the checkpoint after a verified success.
func runReviewResolveCategory(
    uuid: String,
    categoryName: String,
    bookmarksPath: String,
    backupsDir: URL,
    statePath: String,
    logPath: String,
    categoriesURL: URL,
    live: Bool
) throws {
    print(live ? "=== LIVE: resolving \(uuid) to \"\(categoryName)\" ===" : "=== DRY RUN: resolving \(uuid) to \"\(categoryName)\" ===")
    print("")

    let pending = try ReviewLog.pendingItems(logPath: logPath)
    guard let item = pending.first(where: { $0.uuid == uuid }) else {
        print("uuid \(uuid) is not a pending review item (already resolved, never flagged, or the uuid is wrong).")
        print("Run `review` to see what's currently pending.")
        return
    }

    let config = try CategoryConfig.load(from: categoriesURL)
    guard let category = config.categories.first(where: { $0.name == categoryName }) else {
        print("Category \"\(categoryName)\" doesn't exist in categories.json. Nothing changed.")
        return
    }
    guard category.enabled else {
        print("Category \"\(categoryName)\" exists but is disabled. Enable it in categories.json first, or choose a different category. Nothing changed.")
        return
    }
    let safariFolder = category.safariFolder

    print("- \(item.title)")
    print("    uuid: \(item.uuid)")
    print("    url:  \(item.url)")
    print("    user-selected category: \(categoryName)  (Safari folder: \"\(safariFolder)\")")

    func logResolution(decision: String, outcome: String) {
        let entry = OrganizeLogEntry(
            timestamp: Date(),
            mode: live ? "live" : "dry-run",
            uuid: item.uuid, title: item.title, url: item.url,
            category: categoryName, confidence: nil,
            classifierReason: nil, needsReview: nil,
            decision: decision, destinationFolder: safariFolder, outcome: outcome,
            trigger: "manual"
        )
        do {
            try OrganizeLog.append(entry, to: logPath)
        } catch {
            print("    (warning: could not write audit log entry: \(error))")
        }
    }

    if !live {
        let root = try BookmarkStore.readRoot(path: bookmarksPath)
        let folderNames = BookmarkStore.topLevelFolderNames(root: root)
        if folderNames.contains(safariFolder) {
            print("    -> WOULD MOVE into \"\(safariFolder)\"")
        } else {
            print("    -> WOULD FAIL: destination folder \"\(safariFolder)\" not found in Safari")
        }
        print("    (dry run - nothing written, checkpoint not advanced. Re-run with --live to actually move it.)")
        // IMPORTANT: this must stay "review", not "user_resolved" or anything else -
        // pending status is derived from the latest log entry per UUID, and a dry
        // run previewed a choice but resolved nothing. Logging this as resolved
        // would make the item silently vanish from `review` before it's actually
        // been moved.
        logResolution(decision: "review", outcome: "dry run preview only - user selected \"\(categoryName)\", not written, still pending")
        return
    }

    print("Taking a fresh timestamped backup before any writes")
    try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)
    print("")

    let moveResult: VerifiedMoveResult
    do {
        moveResult = try VerifiedMove.moveAndVerify(uuid: uuid, toFolderNamed: safariFolder, bookmarksPath: bookmarksPath)
    } catch {
        let reason = "\(error)"
        print("    -> FAILED: \(reason)")
        logResolution(decision: "failed", outcome: reason)
        return
    }

    if !moveResult.success {
        let reason = "verification failed - " + moveResult.failures.joined(separator: "; ")
        print("    -> FAILED: \(reason)")
        print("       (left unresolved for retry; nothing else was touched by this check)")
        logResolution(decision: "failed", outcome: reason)
        return
    }

    do {
        try KnownBookmarksStore.markProcessed(uuid: uuid, statePath: statePath)
    } catch {
        let reason = "moved and verified, but failed to advance checkpoint: \(error) - will need to be retried"
        print("    -> FAILED: \(reason)")
        logResolution(decision: "failed", outcome: reason)
        return
    }

    print("    -> RESOLVED into \"\(safariFolder)\", verified, checkpoint advanced")
    logResolution(decision: "user_resolved", outcome: "user-selected category, moved and verified")
}

/// User explicitly chose to leave a pending review item alone. The bookmark is NOT
/// moved - Safari's plist is never touched by this path - but the checkpoint is
/// advanced so it stops being reported as new/pending on future runs.
func runReviewResolveSkip(uuid: String, statePath: String, logPath: String) throws {
    let pending = try ReviewLog.pendingItems(logPath: logPath)
    guard let item = pending.first(where: { $0.uuid == uuid }) else {
        print("uuid \(uuid) is not a pending review item (already resolved, never flagged, or the uuid is wrong).")
        print("Run `review` to see what's currently pending.")
        return
    }

    print("- \(item.title)")
    print("    uuid: \(item.uuid)")
    print("    url:  \(item.url)")
    print("    user chose: skip - the organizer will not move this bookmark")

    do {
        try KnownBookmarksStore.markProcessed(uuid: uuid, statePath: statePath)
    } catch {
        print("    -> FAILED to advance checkpoint: \(error). Nothing else changed; nothing was moved.")
        return
    }

    print("    -> SKIPPED: checkpoint advanced, bookmark left exactly where it is")

    let entry = OrganizeLogEntry(
        timestamp: Date(),
        mode: "live",
        uuid: item.uuid, title: item.title, url: item.url,
        category: nil, confidence: nil,
        classifierReason: nil, needsReview: nil,
        decision: "user_skipped", destinationFolder: nil,
        outcome: "user explicitly skipped - not moved, checkpoint advanced",
        trigger: "manual"
    )
    do {
        try OrganizeLog.append(entry, to: logPath)
    } catch {
        print("    (warning: could not write audit log entry: \(error))")
    }
}
