import Foundation

enum WatchControlError: Error, CustomStringConvertible {
    case binaryNotFound(String)

    var description: String {
        switch self {
        case .binaryNotFound(let dir):
            return "No built binary found under \(dir)/.build. Run `swift build -c release` (recommended for a background process) or `swift build` first, then try again."
        }
    }
}

enum LaunchAgentKind: String, CaseIterable {
    case watch = "com.amberjessup.safaribookmarkorganizer.watch"
    case fallback = "com.amberjessup.safaribookmarkorganizer.fallback"

    var plistFilename: String { "\(rawValue).plist" }
    var subcommand: String { self == .watch ? "watch" : "watch-fallback" }
}

/// Phase 10, requirement 5: explicit enable/disable/status. Nothing in this whole
/// project ever installs or loads a LaunchAgent except an explicit `watch enable`
/// call - never automatically, never as a side effect of building.
enum WatchControl {
    static var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    static func plistPath(for kind: LaunchAgentKind) -> URL {
        launchAgentsDir.appendingPathComponent(kind.plistFilename)
    }

    private static func resolveBinaryPath(projectDir: URL) throws -> URL {
        let release = projectDir.appendingPathComponent(".build/release/SafariBookmarkOrganizer")
        let debug = projectDir.appendingPathComponent(".build/debug/SafariBookmarkOrganizer")
        if FileManager.default.isExecutableFile(atPath: release.path) { return release }
        if FileManager.default.isExecutableFile(atPath: debug.path) { return debug }
        throw WatchControlError.binaryNotFound(projectDir.path)
    }

    private static func plistContent(kind: LaunchAgentKind, binaryPath: URL, projectDir: URL, homeDir: URL) -> String {
        let stateDir = homeDir.appendingPathComponent(".safari-organizer/state")
        let outLog = stateDir.appendingPathComponent("\(kind.rawValue).stdout.log").path
        let errLog = stateDir.appendingPathComponent("\(kind.rawValue).stderr.log").path
        // watch: RunAtLoad + KeepAlive, so launchd starts it on login/enable and
        // restarts it if it ever exits. fallback: StartInterval only, a one-shot
        // run every 900 seconds (~15 minutes) - not RunAtLoad, since `organize
        // --live` doesn't need to run the instant the agent is loaded, and the
        // watcher will typically have already handled anything genuinely new.
        let scheduling: String
        switch kind {
        case .watch:
            scheduling = "<key>RunAtLoad</key><true/>\n    <key>KeepAlive</key><true/>"
        case .fallback:
            scheduling = "<key>RunAtLoad</key><false/>\n    <key>StartInterval</key><integer>900</integer>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(kind.rawValue)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath.path)</string>
                <string>\(kind.subcommand)</string>
            </array>
            <key>WorkingDirectory</key>
            <string>\(projectDir.path)</string>
            \(scheduling)
            <key>StandardOutPath</key>
            <string>\(outLog)</string>
            <key>StandardErrorPath</key>
            <string>\(errLog)</string>
        </dict>
        </plist>
        """
    }

    private static func launchctlUID() -> String { String(getuid()) }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "failed to launch launchctl: \(error)")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func enable(projectDir: URL) throws {
        let binaryPath = try resolveBinaryPath(projectDir: projectDir)
        let home = FileManager.default.homeDirectoryForCurrentUser
        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".safari-organizer/state"), withIntermediateDirectories: true)

        print("Using binary: \(binaryPath.path)")
        print("")

        for kind in LaunchAgentKind.allCases {
            let content = plistContent(kind: kind, binaryPath: binaryPath, projectDir: projectDir, homeDir: home)
            let dest = plistPath(for: kind)
            try content.write(to: dest, atomically: true, encoding: .utf8)

            let target = "gui/\(launchctlUID())/\(kind.rawValue)"
            runLaunchctl(["bootout", target]) // fine if it wasn't loaded - ignore the result
            let bootstrap = runLaunchctl(["bootstrap", "gui/\(launchctlUID())", dest.path])
            if bootstrap.status != 0 {
                print("Warning: launchctl bootstrap for \(kind.rawValue) exited \(bootstrap.status): \(bootstrap.output)")
            } else {
                print("Loaded \(kind.rawValue) (\(kind == .watch ? "runs continuously" : "runs every 15 minutes"))")
            }
        }
        print("")
        print("Watcher enabled.")
        print("Logs: \(home.appendingPathComponent(".safari-organizer/state").path)")
        print("Run `SafariBookmarkOrganizer watch status` in a moment to confirm it's actually running.")
    }

    static func disable() {
        for kind in LaunchAgentKind.allCases {
            let target = "gui/\(launchctlUID())/\(kind.rawValue)"
            let result = runLaunchctl(["bootout", target])
            print(result.status == 0 ? "Stopped \(kind.rawValue)" : "\(kind.rawValue): not loaded (or already stopped)")

            let dest = plistPath(for: kind)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
                print("Removed \(dest.path)")
            }
        }
        print("Watcher disabled. Existing bookmarks and the checkpoint/audit log are untouched.")
    }

    static func status() {
        for kind in LaunchAgentKind.allCases {
            let dest = plistPath(for: kind)
            let installed = FileManager.default.fileExists(atPath: dest.path)
            let target = "gui/\(launchctlUID())/\(kind.rawValue)"
            let printResult = runLaunchctl(["print", target])
            let loaded = printResult.status == 0

            print("\(kind.rawValue):")
            print("  installed: \(installed ? "yes (\(dest.path))" : "no")")
            print("  loaded:    \(loaded ? "yes" : "no")")
            if loaded {
                if printResult.output.contains("state = running") {
                    print("  running:   yes")
                } else if let stateLine = printResult.output.split(separator: "\n").first(where: { $0.contains("state = ") }) {
                    print("  running:   \(stateLine.trimmingCharacters(in: .whitespaces))")
                } else {
                    print("  running:   unclear - run `launchctl print \(target)` directly for full detail")
                }
            }
            print("")
        }

        let lastLines = WatchLog.lastLines(10)
        if lastLines.isEmpty {
            print("No watch.log yet (\(WatchLog.path)).")
        } else {
            print("Last \(lastLines.count) watch.log line(s):")
            for line in lastLines { print("  \(line)") }
        }
        print("")

        if let pending = try? ReviewLog.pendingItems(logPath: OrganizeLog.defaultLogPath) {
            print("Pending review items: \(pending.count)\(pending.isEmpty ? "" : " (run `review` to see them)")")
        }
    }
}
