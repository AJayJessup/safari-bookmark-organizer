import Foundation

/// TEST FIXTURE ONLY. The Phase 9 test bookmarks (phase9TestA/B) classified
/// confidently instead of triggering needs_review, so there was nothing real in
/// review to test `review`/`review resolve` against. This looks up their real UUIDs
/// (added by phase9-test-setup, so they genuinely exist in Safari) and appends two
/// clearly synthetic "review" audit-log entries for them, so the review/resolve
/// mechanism itself - audit-log-derived pending status, category resolution with
/// verification, skip, checkpoint behavior, distinct logging - can be tested
/// independently of whether the classifier happens to hedge on a given run. These
/// are NOT real classifier outputs; every field says so.
func runPhase9ForceReview(bookmarksPath: String, logPath: String) throws {
    let root = try BookmarkStore.readRoot(path: bookmarksPath)
    let flat = BookmarkStore.flatten(root: root)

    guard let a = flat.first(where: { $0.title == phase9TestATitle && $0.url == phase9TestAURL }) else {
        print("Could not find bookmark A (\"\(phase9TestATitle)\") in Safari. Run phase9-test-setup first.")
        return
    }
    guard let b = flat.first(where: { $0.title == phase9TestBTitle && $0.url == phase9TestBURL }) else {
        print("Could not find bookmark B (\"\(phase9TestBTitle)\") in Safari. Run phase9-test-setup first.")
        return
    }

    let entryA = OrganizeLogEntry(
        timestamp: Date(),
        mode: "live",
        uuid: a.uuid, title: a.title, url: a.url,
        category: "Consume", confidence: 0.65,
        classifierReason: "[TEST FIXTURE, not a real classification] ambiguous between watching for entertainment and structured learning",
        needsReview: true,
        decision: "review",
        destinationFolder: nil,
        outcome: "[TEST FIXTURE] needs_review flagged by classifier",
        trigger: "manual"
    )
    let entryB = OrganizeLogEntry(
        timestamp: Date(),
        mode: "live",
        uuid: b.uuid, title: b.title, url: b.url,
        category: "Learn", confidence: 0.6,
        classifierReason: "[TEST FIXTURE, not a real classification] podcast used for language study, but could be leisure listening",
        needsReview: false,
        decision: "review",
        destinationFolder: nil,
        outcome: "[TEST FIXTURE] confidence 0.6 below threshold 0.75",
        trigger: "manual"
    )
    try OrganizeLog.append(entryA, to: logPath)
    try OrganizeLog.append(entryB, to: logPath)
    print("Appended 2 synthetic TEST FIXTURE review entries to the audit log:")
    print("  \(a.uuid)  \"\(a.title)\"")
    print("  \(b.uuid)  \"\(b.title)\"")
    print("These are clearly labeled as test fixtures in the log, not real classifier output.")
}
