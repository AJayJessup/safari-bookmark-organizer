// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SafariBookmarkOrganizer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SafariBookmarkOrganizer",
            path: "Sources/SafariBookmarkOrganizer",
            linkerSettings: [
                // Phase 10: the watcher uses FSEvents (CoreServices) to watch
                // Bookmarks.plist - resilient to atomic-replace writes in a way a
                // plain kqueue/DispatchSource file watch is not.
                .linkedFramework("CoreServices")
            ]
        )
    ]
)
