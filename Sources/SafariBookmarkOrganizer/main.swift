import Foundation

let bookmarksPath = ("~/Library/Safari/Bookmarks.plist" as NSString).expandingTildeInPath
let projectDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let backupsDir = projectDir.appendingPathComponent("backups")
let categoriesURL = projectDir.appendingPathComponent("Config/categories.json")
let statePath = KnownBookmarksStore.defaultStatePath
let logPath = OrganizeLog.defaultLogPath

func usage() {
    print("""
    Usage: SafariBookmarkOrganizer <command>

    Commands:
      tree            Print the Safari bookmark folder tree (read-only, no writes)
      backup          Create a snapshot of Bookmarks.plist into ./backups
                        (writes only into ./backups, never touches Safari's file)
      categories      Print the loaded category configuration from Config/categories.json
      classify-test   Run the Classifier against 4 known test bookmarks (no Safari access)
      phase6-test     LIVE WRITE TEST: backs up, creates one synthetic disposable
                        bookmark, moves it into Play, verifies the result. Approved
                        test - see project conversation log.
      phase6-cleanup  Deletes the synthetic phase6-test bookmark and verifies the
                        tree is back to its pre-test state. Approved cleanup step.
      baseline        Phase 7: records every current bookmark/folder UUID as
                        "known" so your existing backlog is never treated as new.
                        Read-only against Safari; writes only the local checkpoint.
      detect-new      Phase 7: reports bookmarks added to Safari since the last
                        checkpoint. Read-only against Safari; does not mark
                        anything as seen.
      organize          Phase 8, DRY RUN (default): shows what detect -> classify ->
                        review/organize decisions WOULD be made. No Safari writes,
                        no checkpoint changes.
      organize --live   Phase 8, LIVE: classifies new bookmarks and moves the ones
                        that clear the confidence threshold into their category
                        folder, verifying each move by UUID before advancing the
                        checkpoint. Low-confidence/needs_review items are left alone
                        for manual review. Requires `baseline` to have been run.
      phase8-test-setup Adds one disposable synthetic bookmark, unfiled, for testing
                        organize end-to-end. Safe to delete afterward.
      phase8-cleanup    Deletes the synthetic phase8-test bookmark, verifies it's
                        gone and nothing else changed. Leaves the checkpoint and
                        audit log untouched.
      review            Phase 9: lists bookmarks currently pending review (status
                        computed from the audit log, not a separate flag).
      review resolve <uuid> --category "Name" [--live]
                        Move a pending review item into a category you chose
                        yourself. Dry run by default; add --live to actually move
                        it. Verifies exactly like organize, by UUID, before
                        advancing the checkpoint. Logged as "user_resolved".
      review resolve <uuid> --skip
                        Leave a pending review item exactly where it is, but advance
                        the checkpoint so it stops being reported. Never touches
                        Safari. Logged as "user_skipped".
      phase9-test-setup Adds two disposable synthetic bookmarks designed to trigger
                        needs_review, for testing review/resolve end-to-end.
      phase9-force-review  TEST FIXTURE ONLY: appends two clearly-labeled synthetic
                        review entries to the audit log for the real phase9-test
                        bookmarks, for testing review/resolve when the classifier
                        didn't actually flag them.
      phase9-cleanup    Deletes both synthetic phase9-test bookmarks by exact UUID,
                        verifies both are gone and nothing else changed. Leaves the
                        checkpoint and audit log (including historical test
                        entries) untouched.
      watch             Phase 10: runs the always-on watcher in the foreground
                        (this is what the LaunchAgent actually executes - you can
                        also run it directly for testing, Ctrl-C to stop). Watches
                        Bookmarks.plist via FSEvents, debounces bursts of writes,
                        and calls the same organize --live pipeline. Never moves a
                        bookmark you've already placed into one of your category
                        folders yourself, and existing bookmarks are never touched -
                        only genuinely new ones. OFF unless enabled below.
      watch enable      Installs and loads the watcher + 15-minute fallback
                        LaunchAgents (~/Library/LaunchAgents). Requires a build to
                        exist first (`swift build -c release` recommended). Not
                        enabled automatically by anything else in this project.
      watch disable     Unloads and removes both LaunchAgents. Existing bookmarks,
                        the checkpoint, and the audit log are untouched.
      watch status      Reports whether each LaunchAgent is installed/loaded/
                        running, the last few watch.log lines, and the current
                        pending-review count.
      watch-fallback    Used internally by the 15-minute fallback LaunchAgent.
                        Equivalent to `organize --live`, tagged trigger "fallback"
                        in the audit log. Safe to run manually too.

    Run this from inside the project directory so relative paths resolve correctly.
    Reads: \(bookmarksPath)
    Checkpoint state: \(statePath)
    Audit log: \(logPath)
    """)
}

do {
    guard CommandLine.arguments.count > 1 else {
        usage()
        exit(1)
    }

    switch CommandLine.arguments[1] {
    case "tree":
        try BookmarkStore.printTree(path: bookmarksPath)

    case "backup":
        try BackupManager.snapshot(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    case "categories":
        let config = try CategoryConfig.load(from: categoriesURL)
        print("Confidence threshold: \(config.confidenceThreshold)")
        print("Tie-break: when ambiguous between \(config.classifierRules.tieBreakCategories), default to \"\(config.classifierRules.tieBreakDefault)\" and flag uncertain: \(config.classifierRules.flagTieBreakAsUncertain)")
        print("")
        for cat in config.categories.sorted(by: { $0.order < $1.order }) {
            let mismatch = cat.name != cat.safariFolder ? "  (Safari folder: \"\(cat.safariFolder)\")" : ""
            print("\(cat.enabled ? "[x]" : "[ ]") \(cat.order). \(cat.name)\(mismatch)")
            print("      \(cat.description)")
        }

    case "classify-test":
        let config = try CategoryConfig.load(from: categoriesURL)
        runClassifierTest(config: config)

    case "phase6-test":
        try runPhase6Test(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    case "phase6-cleanup":
        try runPhase6Cleanup(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    case "baseline":
        try runBaseline(bookmarksPath: bookmarksPath, statePath: statePath)

    case "detect-new":
        try runDetectNew(bookmarksPath: bookmarksPath, statePath: statePath)

    case "organize":
        var live = false
        var limit: Int?
        var argIndex = 2
        var badUsage = false
        while argIndex < CommandLine.arguments.count {
            switch CommandLine.arguments[argIndex] {
            case "--live":
                live = true
                argIndex += 1
            case "--dry-run":
                live = false
                argIndex += 1
            case "--limit":
                guard argIndex + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[argIndex + 1]), n > 0 else {
                    badUsage = true
                    argIndex = CommandLine.arguments.count
                    break
                }
                limit = n
                argIndex += 2
            default:
                badUsage = true
                argIndex = CommandLine.arguments.count
            }
        }
        guard !badUsage else {
            print("Usage: organize [--live|--dry-run] [--limit N]")
            exit(1)
        }
        try runOrganize(bookmarksPath: bookmarksPath, backupsDir: backupsDir, statePath: statePath, logPath: logPath, categoriesURL: categoriesURL, live: live, limit: limit)

    case "phase8-test-setup":
        try runPhase8SetupTestBookmark(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    case "phase8-cleanup":
        try runPhase8Cleanup(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    case "review":
        if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "resolve" {
            guard CommandLine.arguments.count > 3 else {
                print("Usage: review resolve <uuid> --category \"Name\" [--live]  OR  review resolve <uuid> --skip")
                exit(1)
            }
            let targetUUID = CommandLine.arguments[3]
            var categoryName: String?
            var skip = false
            var live = false
            var i = 4
            var badUsage = false
            while i < CommandLine.arguments.count {
                switch CommandLine.arguments[i] {
                case "--category":
                    guard i + 1 < CommandLine.arguments.count else { badUsage = true; i = CommandLine.arguments.count; break }
                    categoryName = CommandLine.arguments[i + 1]
                    i += 2
                case "--skip":
                    skip = true
                    i += 1
                case "--live":
                    live = true
                    i += 1
                case "--dry-run":
                    live = false
                    i += 1
                default:
                    badUsage = true
                    i = CommandLine.arguments.count
                }
            }
            guard !badUsage, (categoryName != nil) != skip else {
                print("Usage: review resolve <uuid> --category \"Name\" [--live]  OR  review resolve <uuid> --skip")
                exit(1)
            }
            if let categoryName {
                try runReviewResolveCategory(uuid: targetUUID, categoryName: categoryName, bookmarksPath: bookmarksPath, backupsDir: backupsDir, statePath: statePath, logPath: logPath, categoriesURL: categoriesURL, live: live)
            } else {
                try runReviewResolveSkip(uuid: targetUUID, statePath: statePath, logPath: logPath)
            }
        } else {
            try runReviewList(logPath: logPath)
        }

    case "phase9-test-setup":
        try runPhase9SetupTestBookmarks(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    case "phase9-force-review":
        try runPhase9ForceReview(bookmarksPath: bookmarksPath, logPath: logPath)

    case "phase9-cleanup":
        try runPhase9Cleanup(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    case "watch":
        if CommandLine.arguments.count > 2 {
            switch CommandLine.arguments[2] {
            case "enable":
                try WatchControl.enable(projectDir: projectDir)
            case "disable":
                WatchControl.disable()
            case "status":
                WatchControl.status()
            default:
                print("Usage: watch | watch enable | watch disable | watch status")
                exit(1)
            }
        } else {
            // The long-running foreground process - this is what the LaunchAgent
            // actually runs. Harmless to run directly for testing; Ctrl-C to stop.
            try runWatch()
        }

    case "watch-fallback":
        // Used internally by the Phase 10 fallback LaunchAgent (every 15 minutes).
        // Equivalent to `organize --live`, tagged trigger "fallback" in the audit log.
        do {
            let summary = try runOrganize(bookmarksPath: bookmarksPath, backupsDir: backupsDir, statePath: statePath, logPath: logPath, categoriesURL: categoriesURL, live: true, limit: nil, trigger: "fallback")
            WatchRunReport.handle(summary)
        } catch {
            WatchLog.append("fallback run failed with error: \(error)")
            Notify.send(title: "Safari Bookmark Organizer", message: "The 15-minute fallback check hit an error: \(error)")
            throw error
        }

    case "phase10-auto-test-setup":
        try runPhase10AutoTestSetup(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    case "phase10-manual-test-setup":
        try runPhase10ManualPlacementSetup(bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    case "phase10-cleanup":
        let uuids = Array(CommandLine.arguments.dropFirst(2))
        try runPhase10Cleanup(uuids: uuids, bookmarksPath: bookmarksPath, backupsDir: backupsDir)

    default:
        usage()
        exit(1)
    }
} catch {
    FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
