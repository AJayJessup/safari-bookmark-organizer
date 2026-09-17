import Foundation
import CoreServices

/// Phase 10: turns organize decisions from `watch`/`watch-fallback` outcomes into
/// logging and (rarely) a macOS notification. Shared by the long-running watcher
/// process and the one-shot 15-minute fallback command, so both report the same way.
/// Deliberately never fires for `.noNewBookmarks` or routine `.review` decisions -
/// only for conditions that actually need your attention.
enum WatchRunReport {
    static func handle(_ summary: OrganizeSummary) {
        switch summary.outcome {
        case .lockHeld:
            WatchLog.append("Skipped - another organize run was already in progress")
        case .noBaseline:
            WatchLog.append("No baseline found - cannot detect new bookmarks")
            Notify.notifyOnce(
                reasonKey: "no_baseline",
                title: "Safari Bookmark Organizer",
                message: "No baseline found. Run `baseline` from Terminal once to fix this - the watcher can't detect new bookmarks until then."
            )
        case .noNewBookmarks:
            WatchLog.append("No new bookmarks found")
        case .ollamaUnreachable:
            WatchLog.append("Ollama unreachable - nothing classified this run")
            Notify.notifyOnce(
                reasonKey: "ollama_unreachable",
                title: "Safari Bookmark Organizer",
                message: "Ollama isn't reachable, so new bookmarks aren't being organized. Start Ollama to resume - you won't be notified again until it recovers."
            )
        case .completed:
            WatchLog.append("Completed: \(summary.userPlacedCount) user-placed, \(summary.organizedCount) organized, \(summary.reviewCount) sent to review, \(summary.failedCount) failed (of \(summary.newCount) new)")
            if summary.failedCount > 0 {
                Notify.notifyOnce(
                    reasonKey: "run_failures",
                    title: "Safari Bookmark Organizer",
                    message: "\(summary.failedCount) bookmark(s) failed to organize or verify. Check \(OrganizeLog.defaultLogPath) - you won't be notified again until a clean run succeeds."
                )
            }
        }
    }
}

enum WatchError: Error, CustomStringConvertible {
    case streamCreationFailed
    case streamStartFailed

    var description: String {
        switch self {
        case .streamCreationFailed: return "Could not create an FSEvents stream for Bookmarks.plist"
        case .streamStartFailed: return "Could not start the FSEvents stream"
        }
    }
}

/// Watches the directory containing Bookmarks.plist via FSEvents (not a plain
/// kqueue/DispatchSource file watch, which loses track of a file the moment its
/// inode is swapped out from under it by an atomic replace - exactly how Safari,
/// and this project's own writer, save the file). Debounces bursts of writes, and
/// suppresses events caused by the organizer's own live writes so it can't
/// re-trigger itself.
final class BookmarksWatcher {
    private let bookmarksPath: String
    private let backupsDir: URL
    private let statePath: String
    private let logPath: String
    private let categoriesURL: URL
    private let debounceInterval: TimeInterval
    // Widened from an initial 2.0s after live testing showed FSEvents' own
    // notification latency for our OWN write (bounded by the stream's configured
    // latency, debounceInterval/2 below - itself up to a couple seconds - plus
    // real dispatch overhead) could land just outside a too-tight window, letting
    // a harmless-but-noisy extra "no new bookmarks" run slip through. 8 seconds
    // comfortably exceeds that, at the cost of (rarely) deferring a bookmark added
    // within 8s of the organizer finishing to the next trigger - never lost, since
    // the 15-minute fallback is the ultimate backstop regardless.
    private let selfWriteGraceWindow: TimeInterval = 8.0

    private var stream: FSEventStreamRef?
    private var debounceTimer: DispatchSourceTimer?
    private var selfWriteInProgress = false
    private var lastSelfWriteFinishedAt: Date?

    init(bookmarksPath: String, backupsDir: URL, statePath: String, logPath: String, categoriesURL: URL, debounceInterval: TimeInterval = 4.0) {
        self.bookmarksPath = bookmarksPath
        self.backupsDir = backupsDir
        self.statePath = statePath
        self.logPath = logPath
        self.categoriesURL = categoriesURL
        self.debounceInterval = debounceInterval
    }

    func start() throws {
        let watchedDir = (bookmarksPath as NSString).deletingLastPathComponent
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { (_, clientCallBackInfo, _, _, _, _) in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<BookmarksWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleRawEvent()
        }

        guard let streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [watchedDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval / 2, // FSEvents' own light coalescing, on top of our debounce
            UInt32(kFSEventStreamCreateFlagFileEvents)
        ) else {
            throw WatchError.streamCreationFailed
        }

        self.stream = streamRef
        FSEventStreamSetDispatchQueue(streamRef, DispatchQueue(label: "com.amberjessup.safaribookmarkorganizer.watch.fsevents"))
        guard FSEventStreamStart(streamRef) else {
            throw WatchError.streamStartFailed
        }
        WatchLog.append("Watcher started, monitoring \(watchedDir)")
    }

    private func handleRawEvent() {
        // Point 8: ignore events while our own write is in flight, or shortly after
        // it finished - without this, the organizer's own verified move would
        // re-trigger itself. A short grace window also absorbs Safari's own trailing
        // metadata touches after an external tool modifies the file.
        if selfWriteInProgress {
            return
        }
        if let finishedAt = lastSelfWriteFinishedAt, Date().timeIntervalSince(finishedAt) < selfWriteGraceWindow {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.scheduleDebouncedRun()
        }
    }

    private func scheduleDebouncedRun() {
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + debounceInterval)
        timer.setEventHandler { [weak self] in
            self?.runOrganizeNow()
        }
        timer.resume()
        debounceTimer = timer
    }

    private func runOrganizeNow() {
        selfWriteInProgress = true
        WatchLog.append("Debounced change detected - running organize --live (trigger: watch)")
        defer {
            selfWriteInProgress = false
            lastSelfWriteFinishedAt = Date()
        }
        do {
            let summary = try runOrganize(
                bookmarksPath: bookmarksPath, backupsDir: backupsDir, statePath: statePath,
                logPath: logPath, categoriesURL: categoriesURL, live: true, limit: nil, trigger: "watch"
            )
            WatchRunReport.handle(summary)
        } catch {
            WatchLog.append("organize run failed with error: \(error)")
            Notify.send(title: "Safari Bookmark Organizer", message: "The watcher hit an unexpected error running organize: \(error)")
        }
    }
}

/// The long-running process a LaunchAgent actually executes (`watch`, no
/// subcommand). Blocks forever - launchd is what starts, restarts (KeepAlive), and
/// stops it.
func runWatch() throws {
    WatchLog.append("Watcher process starting (pid \(ProcessInfo.processInfo.processIdentifier))")
    let watcher = BookmarksWatcher(bookmarksPath: bookmarksPath, backupsDir: backupsDir, statePath: statePath, logPath: logPath, categoriesURL: categoriesURL)
    do {
        try watcher.start()
    } catch {
        WatchLog.append("Watcher failed to start: \(error)")
        Notify.send(title: "Safari Bookmark Organizer", message: "The watcher failed to start: \(error)")
        throw error
    }
    RunLoop.main.run()
}
