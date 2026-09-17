import Foundation

/// Phase 10, requirement 6: concurrency protection. Lives inside the organize
/// pipeline itself (not in `watch` or `main.swift`'s dispatch) so every entry point -
/// the watcher's debounced trigger, the 15-minute fallback, and a manual
/// `organize --live` from Terminal - automatically shares the same guard without
/// needing to remember to add it in three separate places.
///
/// Uses flock(2) on a small lock file. flock is held by the OS per file descriptor
/// and is released automatically if the owning process dies for any reason,
/// including a hard crash or kill -9 - so a stale lock that blocks forever should not
/// be possible with this mechanism.
enum OrganizeLock {
    static var lockPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".safari-organizer/state/organize.lock").path
    }

    final class Handle {
        private let fd: Int32
        private var released = false
        fileprivate init(fd: Int32) { self.fd = fd }

        func release() {
            guard !released else { return }
            released = true
            flock(fd, LOCK_UN)
            close(fd)
        }

        deinit { release() }
    }

    /// Non-blocking: returns immediately. nil means another process currently holds
    /// the lock - the caller should skip this run rather than wait or queue.
    static func tryAcquire() -> Handle? {
        let dir = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return Handle(fd: fd)
    }
}
