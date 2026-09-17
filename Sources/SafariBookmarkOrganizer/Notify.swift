import Foundation

/// Phase 10, requirement 4: local logging plus macOS notifications for MEANINGFUL
/// failures only - never for routine review items, and never on every 15-minute
/// repeat of the same ongoing problem.
///
/// Design: each distinct kind of problem has a "reason key". notifyOnce(reasonKey:)
/// sends a real macOS notification only the first time that reason key is seen since
/// it was last reset; resetReason(_:) clears it (called from the organize pipeline
/// itself on the corresponding successful condition - e.g. a successful Ollama
/// health check resets "ollama_unreachable"). This is state bookkeeping only and is
/// safe to call from manual CLI runs too; only `watch` and `watch-fallback` ever
/// call notifyOnce, so a manual `organize --live` from Terminal never pops a
/// notification.
struct NotifyState: Codable {
    var notifiedReasons: [String]
}

enum Notify {
    /// ~/.safari-organizer/state/notify_state.json
    static var stateFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".safari-organizer/state/notify_state.json").path
    }

    private static func loadState() -> NotifyState {
        guard let data = FileManager.default.contents(atPath: stateFilePath),
              let state = try? JSONDecoder().decode(NotifyState.self, from: data) else {
            return NotifyState(notifiedReasons: [])
        }
        return state
    }

    private static func saveState(_ state: NotifyState) {
        let dir = (stateFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: stateFilePath), options: .atomic)
    }

    /// Sends a macOS user notification via osascript. Best-effort: a failure here is
    /// logged, never thrown - a broken notification must never interrupt organizing.
    static func send(title: String, message: String) {
        let script = "display notification \"\(escape(message))\" with title \"\(escape(title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            process.waitUntilExit()
            WatchLog.append("Notification sent: \(title) - \(message)")
        } catch {
            WatchLog.append("Failed to send notification (\(title) - \(message)): \(error)")
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Sends a notification for `reasonKey` only if it hasn't already been sent
    /// since the last reset for that same reason - this is what prevents the same
    /// ongoing outage from notifying every 15 minutes.
    static func notifyOnce(reasonKey: String, title: String, message: String) {
        var state = loadState()
        guard !state.notifiedReasons.contains(reasonKey) else { return }
        send(title: title, message: message)
        state.notifiedReasons.append(reasonKey)
        saveState(state)
    }

    /// Clears a reason key so a future recurrence of that problem notifies again.
    static func resetReason(_ reasonKey: String) {
        var state = loadState()
        guard state.notifiedReasons.contains(reasonKey) else { return }
        state.notifiedReasons.removeAll { $0 == reasonKey }
        saveState(state)
    }
}
