# Safari Intelligent Bookmark Organizer — Phase 1 Technical Proposal

Date: 2026-09-17
Target: macOS 27 "Golden Gate", Safari 27, Apple Silicon (this Mac)

This is investigation only. Nothing has been read from or written to Safari yet.

## 1. Environment confirmed

- macOS 27 "Golden Gate" shipped 2026-09-14 (three days ago) — this is a current, real
  OS version, not a hypothetical. Safari 27 ships with it.
- No feature-level changes to bookmarks or bookmark sync were found in Safari 27's
  release coverage (the Safari headline features are AI tab grouping, website change
  notifications, natural-language extensions, pull-to-refresh, password manager
  updates — bookmarks are untouched).
- One macOS 27 change is directly relevant and did NOT exist in older macOS versions:
  a new "Application Support Protection" mechanism that uses xattrs to lock down
  `~/Library/Application Support/<name>` for a hand-picked list of non-sandboxed apps,
  independent of Full Disk Access — even a process with FDA can get "Operation not
  permitted" against a protected folder. Apple has not published the full protected-app
  list. This targets *Application Support*, not `~/Library/Safari/`, so it should not
  block bookmark access — but since Safari is exactly the kind of high-value app this
  feature exists to protect, this needs an empirical check in Phase 2, not an assumption.
- Also relevant for later phases: macOS 27's launchd no longer loads LaunchAgent plist
  files that still carry the `com.apple.quarantine` extended attribute. If we write the
  LaunchAgent plist to disk from a downloaded/quarantined context, we must
  `xattr -d com.apple.quarantine` it before `launchctl` will accept it.

## 2. Bookmark storage

- Confirmed current: Safari still stores all bookmarks in one file —
  `~/Library/Safari/Bookmarks.plist` — in binary plist format. No source found
  indicates a move to SQLite or any other store for local bookmark data as of
  Safari 27.
- Structure (from prior-version tooling; needs byte-level confirmation against the
  actual file in Phase 2 since we should not assume old docs are still 100% accurate):
  - Each node is a dictionary with `WebBookmarkType`: `WebBookmarkTypeLeaf` (a bookmark)
    or `WebBookmarkTypeList` (a folder).
  - A bookmark leaf has `URLString` and a `URIDictionary` containing `title`.
  - A folder has `Title` and a `Children` array of child nodes (recursive).
  - Prior Safari versions included a `WebBookmarkUUID` per node — this is the field
    Phase 2 needs to verify still exists and is stable, since it's the cleanest way to
    detect "genuinely new" bookmarks (diff UUIDs, not titles/URLs, which can repeat or
    change).
- Safari actively writes this file during normal use, so both reads and writes must be
  defensive: read with retry/backoff if the file is mid-write, and write atomically
  (write to a temp file in the same directory, then `rename()` over the original) so
  Safari never sees a half-written file.

## 3. Permissions required

- Full Disk Access (System Settings > Privacy & Security > Full Disk Access) has been
  required since macOS 10.14 for any process reading or writing another app's data in
  `~/Library`, including Safari's bookmarks file. All available sources treat this as
  still true for macOS 27. This must be granted to whatever binary actually opens the
  file — if we ship a compiled Swift executable, that executable needs FDA (not the
  terminal, not Xcode).
- This is also why the app should NOT be built as a sandboxed application. A sandboxed
  app is largely confined to its container and typically cannot be granted meaningful
  Full Disk Access to arbitrary paths like `~/Library/Safari/`. A plain, non-sandboxed
  Swift executable (or a minimal unsandboxed .app wrapper) is the only realistic way to
  get durable FDA to Safari's bookmark file.
- Distinct from FDA: whether the new Application Support Protection (see §1) blocks us.
  Our own app's data (backups, history, config) should live in our own
  `~/Library/Application Support/SafariBookmarkOrganizer/` or inside this project
  folder — either is fine since that protection is about *other* apps' folders, not
  restricting an app from using its own.

## 4. Read/write mechanism

- Read: parse the binary plist with Foundation's `PropertyListSerialization` /
  `PropertyListDecoder` (Swift). No third-party plist library needed.
- Write: never edit Safari's live file directly. Read → build the new tree in memory →
  serialize → write to a temp file in `~/Library/Safari/` → atomic rename over
  `Bookmarks.plist`. Third-party tooling (safari-bookmarks-cli) reports Safari picks up
  external changes to this file automatically ("reloaded without intervention" when it
  detects the file changed) — so we should not need to quit or relaunch Safari for a
  change to appear. This claim should be verified empirically in Phase 6 before relying
  on it (test with Safari open, watching whether a moved test bookmark appears live).
- Every write is preceded by a snapshot (Phase 3), and only ever moves/re-parents
  existing nodes — never deletes bookmark data.

## 5. Change detection / watcher

- FSEvents is the right lightweight, event-driven mechanism to know when
  `Bookmarks.plist` changed, without polling. No evidence macOS 27 changed the FSEvents
  API. We'll wrap it via `DispatchSource` file-system-object monitoring or the FSEvents
  C API from Swift.
- FSEvents only tells us "the file changed" — it does not tell us *what* changed. Per
  the spec, on every fire we:
  1. Parse the new tree.
  2. Diff it against our last-known tree (keyed by `WebBookmarkUUID`, once confirmed in
     Phase 2 — falling back to a `(URLString, parent folder path)` composite key if UUIDs
     turn out to be unreliable).
  3. Any UUID/key present now that wasn't in the last-known tree is a genuinely new
     bookmark. Everything else (reorders, unrelated folder edits, deletions) is ignored.
  4. Update the last-known tree snapshot after processing.
- This satisfies the "don't reclassify the whole library on every file touch" and
  "don't treat every modification as a new bookmark" requirements directly.

## 6. Language / framework recommendation

**Swift, built as a small non-sandboxed command-line executable (Swift Package Manager,
not an Xcode .app target), run as a LaunchAgent.**

Why:
- Native Apple Silicon, no runtime dependency to install (ships with macOS).
- Foundation gives us plist parsing, FSEvents-adjacent file monitoring, and URLSession
  for the AI classification calls — no extra libraries required for the core loop.
- A plain executable (vs. a sandboxed .app) is what makes durable Full Disk Access
  realistic (see §3).
- LaunchAgents are the standard, lightweight, event-driven-friendly way to run a small
  background utility on demand rather than as a constantly-running process — it can be
  configured to launch on a `WatchPaths` trigger (pointed at `Bookmarks.plist`) so
  launchd itself only wakes the process when the file actually changes, rather than us
  running our own always-on watcher process. This is likely the *best-fit* mechanism
  for "lightweight, event-driven, dormant when idle" and should be the primary watcher
  design, with our own FSEvents-based diffing (§5) running inside that short-lived
  process invocation rather than a long-lived daemon.
- Python was considered and rejected as the primary implementation: it would need a
  bundled interpreter or a `.pkg` install, doesn't get first-class LaunchAgent/FDA
  ergonomics, and offers no real advantage here over Swift/Foundation for plist
  handling. AppleScript was considered and rejected: Safari's AppleScript dictionary
  doesn't expose bookmark folder manipulation, only tabs/windows/content — it can't do
  the actual moving of bookmarks between folders.

## 7. Proposed project layout (created now, empty except this document)

```
Safari Bookmark Organizer/
  PHASE1_PROPOSAL.md        <- this file
  Package.swift             <- Phase 2
  Sources/
    SafariBookmarkOrganizer/
  backups/                  <- Phase 3, gitignored / kept local only
  (no code yet — Phase 2 starts the read-only prototype)
```

## 8. Explicitly unresolved — to verify in Phase 2, not assumed

- Whether `WebBookmarkUUID` (or an equivalent stable identifier) is still present per
  node in a live macOS 27 Bookmarks.plist.
- Whether the Application Support Protection in §1 has any bearing on
  `~/Library/Safari/` specifically (expected: no, but unverified).
- Whether Safari really does hot-reload an externally-modified Bookmarks.plist with no
  visible glitch, or whether a relaunch/nudge is needed in practice.
- Exact behavior of Full Disk Access prompting for a freshly-built, ad-hoc-signed
  Swift executable (whether it needs to be run once to appear in the FDA list, code
  signing requirements, etc.).

## 9. Proposed Phase 2 (next step, not started)

Build the read-only prototype: request Full Disk Access, read
`~/Library/Safari/Bookmarks.plist`, print the folder tree with titles/URLs and (if
present) UUIDs. Zero writes. This will resolve every item in §8.
