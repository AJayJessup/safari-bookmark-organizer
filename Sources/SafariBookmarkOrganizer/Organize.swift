import Foundation

enum OrganizeRunOutcome {
    case lockHeld
    case noBaseline
    case noNewBookmarks
    case ollamaUnreachable
    case completed
}

/// What a run actually did, returned so automatic callers (watch, watch-fallback)
/// can decide whether to notify - this function itself never pops a notification,
/// so a manual `organize --live` from Terminal stays silent, exactly as before.
struct OrganizeSummary {
    let outcome: OrganizeRunOutcome
    var organizedCount: Int = 0
    var reviewCount: Int = 0
    var failedCount: Int = 0
    var userPlacedCount: Int = 0
    var newCount: Int = 0
}

/// Phase 8: detect -> classify -> evaluate confidence/needs_review -> organize or
/// review -> verify -> advance the checkpoint. WebBookmarkUUID is the identity of a
/// bookmark throughout - title/URL are never assumed unique, since Safari allows the
/// same URL (even the same title) saved multiple times as genuinely separate
/// bookmarks.
///
/// Phase 10 additions, all additive to this same pipeline (no new Safari-write logic
/// anywhere in this file):
///  - a concurrency lock (OrganizeLock) acquired before anything else, so watch,
///    the 15-minute fallback, and a manual `organize --live` can never overlap
///  - a manual-placement check: a bookmark already sitting inside one of your
///    configured category folders by the time we get here was placed there by you,
///    not us - it's left alone, never classified, never moved, just checkpointed
///  - a `trigger` tag ("manual"/"watch"/"fallback") on every audit log entry
///  - a returned OrganizeSummary instead of only printing, so watch/fallback can
///    decide whether a run's outcome is worth a notification
@discardableResult
func runOrganize(
    bookmarksPath: String,
    backupsDir: URL,
    statePath: String,
    logPath: String,
    categoriesURL: URL,
    live: Bool,
    limit: Int? = nil,
    trigger: String = "manual"
) throws -> OrganizeSummary {
    guard let lock = OrganizeLock.tryAcquire() else {
        print("Another organize run is already in progress (lock at \(OrganizeLock.lockPath)). Skipping this run - nothing was touched.")
        return OrganizeSummary(outcome: .lockHeld)
    }
    defer { lock.release() }

    print(live ? "=== LIVE RUN - Safari will be written to ===" : "=== DRY RUN - no Safari writes, no checkpoint changes ===")
    print("")

    let config = try CategoryConfig.load(from: categoriesURL)
    let enabledNames = Set(config.categories.filter { $0.enabled }.map { $0.name })
    let folderByCategory = Dictionary(uniqueKeysWithValues: config.categories.map { ($0.name, $0.safariFolder) })
    let allCategoryFolders = Set(config.categories.map { $0.safariFolder })

    guard let known = try KnownBookmarksStore.loadIfExists(from: statePath) else {
        print("No baseline found at \(statePath).")
        print("Run `baseline` first, so your existing bookmarks aren't treated as new.")
        return OrganizeSummary(outcome: .noBaseline)
    }
    Notify.resetReason("no_baseline")

    let root = try BookmarkStore.readRoot(path: bookmarksPath)
    let flat = BookmarkStore.flatten(root: root)
    let allNewOnes = flat.filter { !known.contains($0.uuid) }

    if allNewOnes.isEmpty {
        print("No new bookmarks since the last checkpoint (\(known.count) known items). Nothing to do.")
        return OrganizeSummary(outcome: .noNewBookmarks)
    }

    var newOnes = allNewOnes
    if let limit, allNewOnes.count > limit {
        newOnes = Array(allNewOnes.prefix(limit))
        print("\(allNewOnes.count) new bookmark(s) found; limiting this run to the first \(limit).")
    } else {
        print("\(newOnes.count) new bookmark(s) to process.")
    }
    print("")

    func log(uuid: String, title: String, url: String, category: String?, confidence: Double?, classifierReason: String?, needsReview: Bool?, decision: String, destinationFolder: String?, outcome: String) {
        let entry = OrganizeLogEntry(
            timestamp: Date(),
            mode: live ? "live" : "dry-run",
            uuid: uuid, title: title, url: url,
            category: category, confidence: confidence,
            classifierReason: classifierReason, needsReview: needsReview,
            decision: decision, destinationFolder: destinationFolder, outcome: outcome,
            trigger: trigger
        )
        do {
            try OrganizeLog.append(entry, to: logPath)
        } catch {
            print("    (warning: could not write audit log entry: \(error))")
        }
    }

    // --- Manual placement wins (Phase 10, requirement 10) ---
    // A bookmark that's already sitting inside one of your configured category
    // folders by the time we get here was placed there by you, not the classifier.
    // Checked before Ollama/backup so a run made up entirely of manual placements
    // never needs either.
    var toClassify: [BookmarkStore.FlatBookmark] = []
    var userPlacedCount = 0
    for bookmark in newOnes {
        guard bookmark.folderPath.count == 1, allCategoryFolders.contains(bookmark.folderPath[0]) else {
            toClassify.append(bookmark)
            continue
        }
        let folderName = bookmark.folderPath[0]
        print("- \(bookmark.title)")
        print("    uuid: \(bookmark.uuid)")
        print("    url:  \(bookmark.url)")
        print("    -> found already in \"\(folderName)\" before processing - treated as manually organized, left in place")
        if live {
            do {
                try KnownBookmarksStore.markProcessed(uuid: bookmark.uuid, statePath: statePath)
                log(uuid: bookmark.uuid, title: bookmark.title, url: bookmark.url, category: nil, confidence: nil, classifierReason: nil, needsReview: nil,
                    decision: "user_placed", destinationFolder: folderName,
                    outcome: "found already inside a category folder (\"\(folderName)\") before processing - treated as manually organized, checkpoint advanced")
            } catch {
                log(uuid: bookmark.uuid, title: bookmark.title, url: bookmark.url, category: nil, confidence: nil, classifierReason: nil, needsReview: nil,
                    decision: "failed", destinationFolder: folderName,
                    outcome: "already in \"\(folderName)\" but failed to advance checkpoint: \(error) - will be retried")
            }
        } else {
            print("    (dry run - would checkpoint without moving, not written)")
            log(uuid: bookmark.uuid, title: bookmark.title, url: bookmark.url, category: nil, confidence: nil, classifierReason: nil, needsReview: nil,
                decision: "user_placed", destinationFolder: folderName,
                outcome: "dry run - already in \"\(folderName)\", would checkpoint without moving, not written")
        }
        userPlacedCount += 1
        print("")
    }

    if toClassify.isEmpty {
        print("=== Summary: \(userPlacedCount) already manually organized, 0 classified, 0 sent to review, 0 failed ===")
        if !live {
            print("(dry run - nothing was written to Safari or the checkpoint)")
        }
        print("Audit log: \(logPath)")
        return OrganizeSummary(outcome: .completed, organizedCount: 0, reviewCount: 0, failedCount: 0, userPlacedCount: userPlacedCount, newCount: allNewOnes.count)
    }

    print("Checking Ollama is reachable...")
    guard Classifier.healthCheck() else {
        print("Ollama isn't reachable at http://localhost:11434.")
        print("Start it and try again - nothing was classified, moved, or marked processed.")
        return OrganizeSummary(outcome: .ollamaUnreachable, userPlacedCount: userPlacedCount, newCount: allNewOnes.count)
    }
    print("Ollama is up.")
    print("")
    Notify.resetReason("ollama_unreachable")

    if live {
        print("Taking a fresh timestamped backup before any writes")
        try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)
        print("")
    }

    var organizedCount = 0
    var reviewCount = 0
    var failedCount = 0

    for bookmark in toClassify {
        let uuid = bookmark.uuid
        let title = bookmark.title
        let url = bookmark.url
        let domain = URL(string: url)?.host ?? ""

        print("- \(title)")
        print("    uuid: \(uuid)")
        print("    url:  \(url)")

        // --- Classify ---
        let classification: ClassificationResult
        do {
            classification = try Classifier.classify(title: title, url: url, domain: domain, config: config)
        } catch {
            let reason = "classification failed: \(error)"
            print("    -> FAILED: \(reason)")
            log(uuid: uuid, title: title, url: url, category: nil, confidence: nil, classifierReason: nil, needsReview: nil,
                decision: "failed", destinationFolder: nil, outcome: reason)
            failedCount += 1
            print("")
            continue
        }

        print("    classified: \(classification.category)  (confidence \(classification.confidence), needs_review \(classification.needsReview))")
        print("    reason: \(classification.reason)")

        // --- Evaluate confidence / needs_review / category validity ---
        var reviewReason: String?
        if classification.needsReview {
            reviewReason = "needs_review flagged by classifier"
        } else if classification.confidence < config.confidenceThreshold {
            reviewReason = "confidence \(classification.confidence) below threshold \(config.confidenceThreshold)"
        } else if !enabledNames.contains(classification.category) {
            reviewReason = "category \"\(classification.category)\" is not an enabled category"
        }

        if let reviewReason {
            print("    -> REVIEW: \(reviewReason)")
            log(uuid: uuid, title: title, url: url, category: classification.category, confidence: classification.confidence,
                classifierReason: classification.reason, needsReview: classification.needsReview,
                decision: "review", destinationFolder: nil, outcome: reviewReason)
            reviewCount += 1
            print("")
            continue
        }

        guard let safariFolder = folderByCategory[classification.category] else {
            let reason = "no Safari folder mapping for category \"\(classification.category)\""
            print("    -> FAILED: \(reason)")
            log(uuid: uuid, title: title, url: url, category: classification.category, confidence: classification.confidence,
                classifierReason: classification.reason, needsReview: classification.needsReview,
                decision: "failed", destinationFolder: nil, outcome: reason)
            failedCount += 1
            print("")
            continue
        }

        // --- Dry run stops here ---
        if !live {
            print("    -> WOULD ORGANIZE into \"\(safariFolder)\"")
            log(uuid: uuid, title: title, url: url, category: classification.category, confidence: classification.confidence,
                classifierReason: classification.reason, needsReview: classification.needsReview,
                decision: "organized", destinationFolder: safariFolder, outcome: "dry run - not written, checkpoint not advanced")
            organizedCount += 1
            print("")
            continue
        }

        // --- Live: move and verify by UUID (shared with `review resolve --category`) ---
        let moveResult: VerifiedMoveResult
        do {
            moveResult = try VerifiedMove.moveAndVerify(uuid: uuid, toFolderNamed: safariFolder, bookmarksPath: bookmarksPath)
        } catch {
            let reason = "\(error)"
            print("    -> FAILED: \(reason)")
            log(uuid: uuid, title: title, url: url, category: classification.category, confidence: classification.confidence,
                classifierReason: classification.reason, needsReview: classification.needsReview,
                decision: "failed", destinationFolder: safariFolder, outcome: reason)
            failedCount += 1
            print("")
            continue
        }

        if !moveResult.success {
            let reason = "verification failed - " + moveResult.failures.joined(separator: "; ")
            print("    -> FAILED: \(reason)")
            print("       (left unprocessed for retry; nothing else was touched by this check)")
            log(uuid: uuid, title: title, url: url, category: classification.category, confidence: classification.confidence,
                classifierReason: classification.reason, needsReview: classification.needsReview,
                decision: "failed", destinationFolder: safariFolder, outcome: reason)
            failedCount += 1
            print("")
            continue
        }

        // --- Verified: advance the checkpoint for this UUID only, now ---
        do {
            try KnownBookmarksStore.markProcessed(uuid: uuid, statePath: statePath)
        } catch {
            // The move succeeded and verified, but we couldn't record it. Leaving
            // this unprocessed means it'll be retried (and re-moved, harmlessly,
            // since moveBookmark is idempotent for a bookmark already in the right
            // folder) rather than silently losing track of it.
            let reason = "moved and verified, but failed to advance checkpoint: \(error) - will be retried next run"
            print("    -> FAILED: \(reason)")
            log(uuid: uuid, title: title, url: url, category: classification.category, confidence: classification.confidence,
                classifierReason: classification.reason, needsReview: classification.needsReview,
                decision: "failed", destinationFolder: safariFolder, outcome: reason)
            failedCount += 1
            print("")
            continue
        }

        print("    -> ORGANIZED into \"\(safariFolder)\", verified, checkpoint advanced")
        log(uuid: uuid, title: title, url: url, category: classification.category, confidence: classification.confidence,
            classifierReason: classification.reason, needsReview: classification.needsReview,
            decision: "organized", destinationFolder: safariFolder, outcome: "moved and verified")
        organizedCount += 1
        print("")
    }

    print("=== Summary: \(userPlacedCount) already manually organized, \(organizedCount) organized, \(reviewCount) sent to review, \(failedCount) failed ===")
    if !live {
        print("(dry run - nothing was written to Safari or the checkpoint)")
    }
    print("Audit log: \(logPath)")

    if failedCount == 0 {
        Notify.resetReason("run_failures")
    }

    return OrganizeSummary(outcome: .completed, organizedCount: organizedCount, reviewCount: reviewCount, failedCount: failedCount, userPlacedCount: userPlacedCount, newCount: allNewOnes.count)
}
