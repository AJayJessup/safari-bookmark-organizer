# Safari Intelligent Bookmark Organizer

Status: early prototype. Safari is the source of truth - this project never has its
own bookmark database. See PHASE1_PROPOSAL.md for the environment investigation this
was built on.

## What exists right now

- `tree`        - read-only: prints your actual Safari bookmark folder tree
- `backup`      - writes a snapshot into ./backups (never touches Safari's file)
- `categories`  - prints the loaded category config from Config/categories.json
- `classify-test` - runs the local AI classifier against known test cases
- `phase6-test` / `phase6-cleanup` - the approved live-write test and its cleanup (see project log)
- `baseline`    - records every current bookmark/folder UUID as known (see "New bookmark detection" below)
- `detect-new`  - reports bookmarks added to Safari since the last checkpoint
- `organize`    - Phase 8 dry run: shows detect -> classify -> review/organize decisions, writes nothing
- `organize --live` - Phase 8 live: classifies and moves qualifying new bookmarks, verifies each move by UUID, advances the checkpoint only on verified success (see "Organizing new bookmarks" below)
- `review`      - Phase 9: lists bookmarks currently pending review
- `review resolve <uuid> --category "Name" [--live]` - move a pending review item to a category you chose; dry run by default
- `review resolve <uuid> --skip` - leave a pending review item alone but stop it being reported again
- `watch`         - Phase 10: runs the always-on watcher in the foreground (what the LaunchAgent actually executes)
- `watch enable` / `watch disable` / `watch status` - install/remove/check the watcher + 15-minute fallback LaunchAgents (OFF by default)
- `watch-fallback` - internal command run by the fallback LaunchAgent every 15 minutes; safe to run manually too

Everything above that writes to Safari's actual Bookmarks.plist (`organize --live`,
`review resolve --category --live`, and the watcher/fallback, which call the same
pipeline) goes through the same UUID-based move-and-verify path and the same
concurrency lock, described below. `BackupManager.restore(...)` exists in code but
is intentionally not wired to any command until it's been tested against a
throwaway copy, per the project's safety rules.

## Build and run

From inside this folder:

    swift build
    swift run SafariBookmarkOrganizer categories
    swift run SafariBookmarkOrganizer tree
    swift run SafariBookmarkOrganizer backup

Run these from *inside* this project folder - `backup` and `categories` use paths
relative to the current directory (./backups, ./Config/categories.json).

## New bookmark detection (Phase 7)

Safari itself is still the only place your bookmarks live. To tell which bookmarks
are genuinely new, the organizer keeps a small local checkpoint file listing which
bookmark/folder UUIDs it has already accounted for:

    ~/.safari-organizer/state/known_bookmarks.json

This is NOT a copy of your bookmark data and NOT a second bookmark database - it's
just a list of UUIDs. It lives outside this project folder entirely, in a user-local
app state directory, specifically so it's never inside the Git repo and can't be
committed or shared by accident.

Workflow:

1. Run `baseline` once. It records every bookmark and folder currently in Safari as
   "already known." Nothing gets classified or moved - this just sets the starting
   point, so your existing backlog is never mistaken for new bookmarks later.
2. Run `detect-new` any time after that. It compares Safari's current bookmarks
   against the checkpoint and reports anything added since. It's read-only against
   Safari, it never writes to Bookmarks.plist, and it does not mark what it finds as
   "seen" - a reported bookmark stays reported on every subsequent run until a real
   classification/processing step (Phase 8, not built yet) advances the checkpoint.

The always-on watcher (FSEvents/LaunchAgent) that would run `detect-new`
automatically hasn't been built yet - see "Not built yet" below.

## Organizing new bookmarks (Phase 8)

`organize` runs the full pipeline: detect new bookmarks (same logic as `detect-new`)
-> classify each with the local Ollama classifier -> evaluate confidence/needs_review
-> either move it into its category folder or leave it for review -> verify the move
by WebBookmarkUUID -> only then advance the checkpoint for that one bookmark.

`WebBookmarkUUID` is the identity of a bookmark everywhere in this pipeline. Safari
allows the same URL, even the same title, saved as multiple separate bookmarks, so
nothing here ever assumes title/URL uniqueness - matching and verification are
UUID-only.

Auto-organize requires ALL of: `needs_review: false`, confidence at or above
`confidenceThreshold` in categories.json, and an enabled category name. Anything
short of that goes to review, logged with why, and is left untouched - it will be
reported again on future runs since it's never marked processed.

Run with no flags for a dry run: full detection and classification, printed
decisions, zero Safari writes, checkpoint untouched. Add `--live` to actually move
qualifying bookmarks. A live run takes one timestamped backup first, checks Ollama
is reachable before starting, and per bookmark: confirms the destination folder
exists, moves it, re-reads the plist fresh from disk, and verifies the exact UUID
exists exactly once, in the right folder, with title/URL unchanged, total leaf count
unchanged, and no other bookmark or folder altered. Only a bookmark that passes all
of that gets marked processed. A failed move, a failed verification, or a bookmark
sent to review is left unprocessed so it's retried (or reviewed) on a later run.

Every decision - organized, review, or failed, and why - is appended to a JSON-lines
audit log at `~/.safari-organizer/state/organize_log.jsonl`, alongside the
checkpoint and outside the Git repo for the same reason.

The always-on watcher isn't built yet, so `organize` has to be run manually for now
while the pipeline is being validated - see "Not built yet".

## Resolving review items (Phase 9)

Anything `organize` sends to review (low confidence, needs_review, or an
unrecognized category) sits there indefinitely - it's never auto-retried or
auto-organized with a lowered bar, and it'll keep being reported until you resolve
it. `review` lists what's currently pending, with the UUID, title, URL, the
classifier's attempted category/confidence/reason, and why it was flagged. Pending
status is computed from the audit log itself (the most recent entry for each UUID),
not a separate flag, so a resolved item stops appearing automatically.

Two ways to resolve one:

`review resolve <uuid> --category "Solve"` - you're explicitly choosing the
category yourself. Requires the category to exist and be enabled in
categories.json. Dry run by default (prints what would happen, nothing written);
add `--live` to actually move it. A live resolution takes a backup first, verifies
the move by UUID exactly like `organize` does, and only advances the checkpoint on
a verified success. Logged as `user_resolved`, distinct from the organizer's own
automatic `organized` decisions.

`review resolve <uuid> --skip` - you're deliberately leaving it alone (maybe
you'll file it yourself, or it's fine where it is). Never touches Safari, but does
advance the checkpoint so it stops being reported. Logged as `user_skipped`.

## Always-on watcher (Phase 10)

Off by default. Nothing in this project enables it automatically - you turn it on
explicitly:

    swift build -c release
    swift run SafariBookmarkOrganizer watch enable
    swift run SafariBookmarkOrganizer watch status
    swift run SafariBookmarkOrganizer watch disable

A release build is recommended before `watch enable` since the watcher is a
long-running background process; `watch enable` falls back to a debug build if
that's all that exists.

`watch enable` installs and loads two user-level LaunchAgents
(`~/Library/LaunchAgents`, not root, not system-wide):

- **watch** - a long-running process that watches Bookmarks.plist via FSEvents,
  waits for writes to settle (~4 seconds of no further changes), then runs the same
  `organize --live` pipeline used everywhere else in this project. Restarted
  automatically by launchd if it ever exits (`KeepAlive`).
- **fallback** - a one-shot `organize --live` every 15 minutes regardless of file
  events, as a safety net for anything FSEvents might miss (rare, but documented as
  possible, especially across sleep/wake).

Both call the exact same pipeline as manual `organize --live` - same backup, same
classification, same confidence/review handling, same UUID-based verified move, same
checkpoint-only-after-success. Every audit log entry now also records a `trigger`
field (`manual`, `watch`, or `fallback`) so you can tell later how a given decision
was triggered.

Safety mechanisms specific to always-on operation:

- **Concurrency lock** - lives inside `runOrganize` itself
  (`~/.safari-organizer/state/organize.lock`), so the watcher, the fallback, and a
  manual `organize --live` can never run at the same time. A run that finds the
  lock held simply skips itself; nothing queues, nothing is touched.
- **Manual placement wins** - if a genuinely new bookmark is already sitting inside
  one of your configured category folders by the time a run gets to it (because you
  put it there yourself), it's left exactly where it is, never classified, and just
  checkpointed. Logged as `user_placed`.
- **Self-trigger suppression** - the watcher ignores file-change events while its
  own live write is in progress, and for a couple of seconds after, so its own
  verified moves can't re-trigger itself into a loop.
- **Existing bookmarks untouched** - automatic mode only ever considers bookmarks
  not already in the checkpoint, exactly like manual `organize`. Reorganizing your
  existing library is a separate, not-yet-built command, run explicitly.
- **Notifications only for meaningful failures** - a real macOS notification (via
  `osascript`) fires for Ollama being unreachable, a verification/move failure, or
  the watcher itself failing to start - never for a routine item sent to review, and
  never on every 15-minute repeat of the same ongoing problem (each condition
  notifies once, then stays quiet until it's resolved and recurs). Manual CLI runs
  from Terminal never trigger a notification, even when they hit the same
  conditions - only the watcher and fallback do.
- **Local logging** - `~/.safari-organizer/state/watch.log` is a plain-text
  operational log (started/stopped, debounced runs, notifications sent), separate
  from the structured per-bookmark JSON-lines audit log.

## Note on categories.json

Your "Relax" category maps to the Safari folder "Relax/Focus", because that's what
the folder is actually named in your live Safari bookmarks right now - the config
points at reality rather than assuming a rename. If you'd rather the Safari folder
itself be renamed to "Relax", that's a write operation we haven't built/tested yet.

## Backups

`backups/ORIGINAL_SAFARI_BOOKMARKS.plist` is the one-time, never-overwritten snapshot
of your bookmarks as they were before this project ever touched anything (created
2026-09-17). Every future `backup` run adds a timestamped snapshot alongside it.
This folder is gitignored - it holds your actual bookmark data and stays local only.

## Not built yet

An explicit command to intentionally reorganize your *existing* bookmark library
(automatic mode, on purpose, only ever touches genuinely new bookmarks - see
"Always-on watcher" above), change history beyond the audit log, category
management commands, and the control-panel UI. Each needs a decision or an approval
before it's built - see the open items in PHASE1_PROPOSAL.md and the conversation
this project came out of.
