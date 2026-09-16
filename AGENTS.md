# AGENTS.md

Guidance for AI agents (and humans) working on **Everywhere** — a native macOS app
built with SwiftUI + AppKit + SQLite.

User-facing overview: [README.md](README.md). Everyday workflows: [User guide](docs/USER_GUIDE.md).

## What this is

An instant file-search app for macOS. It builds on the classic instant-search
techniques, adapted to macOS:

| Concept | Everywhere implementation |
|---|---|
| NTFS MFT bulk read | `getattrlistbulk` directory reader (one syscall per ~500 entries), POSIX `readdir`+`lstat` fallback |
| USN change journal | **FSEvents** journal replay + live stream → debounced diff-based `Reconciler` |
| In-memory index | Optional packed filename/metadata cache, backed by **SQLite** (WAL) with name-only FTS5 |

## Layout

```
Sources/EverywhereCore/        library (no UI)
  Database.swift               SQLite schema, search engines, path materialization
  FilenameIndex.swift          packed names, incremental cache refresh, bounded fast sort orders
  SearchCancellation.swift     cooperative search cancellation and SQLite progress handler token
  Entry.swift                  Entry/IndexRow/SearchRequest/SearchResult/query builder
  SearchQueryParser.swift      query-language parser (| ! quotes, wildcard/slash flags)
  Indexer.swift                FilesystemIndexer (initial walk) + Reconciler (diff updates)
  FSEventsMonitor.swift        FSEventStream wrapper + ChangeHandler (debounced ingest)
  IndexService.swift           serial scan jobs, startup replay, monitoring, published state
  IndexCheckpoint.swift        persistent journal cursor, baseline/config/volume validation
  IndexingControl.swift        cooperative pause/resume/cancellation via NSCondition
  IndexSettings.swift          UserDefaults-backed settings (roots, exclusions, live toggle)
Sources/Everywhere/            app (SwiftUI + AppKit)
  EverywhereApp.swift          @main, scenes, Search menu commands
  AppDelegate.swift            stable main-window registration, openWindow fallback, activation
  ContentView.swift            toolbar search/modifier toggles, status bar, empty state
  SearchField.swift            NSSearchField bridge and search-focus handling
  IndexingProgressView.swift   compact spinner, counts, Pause/Resume control
  ContentViewModel.swift       debounced search scheduling, selection actions
  ResultsTableView.swift       NSTableView (native sortable columns, context menu, Open With)
  SettingsView.swift           Settings scene
  StatusItemController.swift   menu bar icon: left-click opens, right-click menu (Quit)
  GlobalHotKey.swift           Carbon RegisterEventHotKey (⌥Space) + HotKeyManager
Resources/AppIcon.svg         source artwork; design details in AppIcon-design.md
Scripts/make-icon.swift        renders SVG source into exact-size ICNS representations
README.md                     overview, requirements, build/install instructions
docs/USER_GUIDE.md             common tasks, query examples, shortcuts, troubleshooting
Tests/EverywhereCoreTests/     XCTest (all logic tests live here; no UI tests)
```

## Commands

```bash
make test      # swift test — MUST pass before finishing any change
make build     # release build
make app       # builds .build/Everywhere.app (signed ad-hoc, bundles icon)
make install   # + copies to /Applications
make dist      # universal release zip + SHA256 for the GitHub release/tap
make bump VERSION=x.y.z
make release VERSION=x.y.z  # test, bump, tag; CI publishes the release and updates the tap
make open      # install + launch
make run       # debug run from CLI
make clean
```

No linter is configured. `swift build` warnings should be treated as errors.

## Architecture invariants — do not break these

These are the decisions that make the app fast and small. If you change one, benchmark
and re-measure both size and speed.

1. **Paths are never stored in full.** `entries` is a parent-pointer tree
   (`id, parent, name`). Full paths are reconstructed at display time via the recursive
   CTE in `materializePaths`/`resolvePath`. Do not add a `path` column or an index over
   full paths — that is what made the index 7.27 GB; the tree design brought it to
   ~230 bytes/row (~500 MB for a full disk).
2. **FTS indexes name only, no `prefix=` option.** FTS prefix indexes triple index size;
   prefix *queries* are already fast from the base index (term-seek + merge).
   Do not add `prefix='…'` back, and do not add a second FTS column.
   `columnsize=0` omits unused ranking token counts; keep full positional detail for phrases.
3. **Root rows** (`parent = 0`) exist for each index root; the `/` root row has an
   empty name and is filtered from results/FTS everywhere (`name != ''`).
   `ensureRootRow` is idempotent; `Reconciler`/`FilesystemIndexer` call it on entry.
4. **IDs are allocated by the app** (`allocateIDs`, block-allocated in `IndexEngine.takeID`),
   not by SQLite autoincrement — parents must have ids before children are inserted.
5. **Upsert conflict target is `(parent, name)`** (UNIQUE index). Renames are handled as
   delete+insert by the Reconciler, not UPDATE.
6. **Search engine routing** (`Database.search`):
   - empty text → `recentItems` (ORDER BY modified DESC, index-backed — do not make this sort)
   - regex + Match Path → `scanSearch` (streaming, regex per row)
   - regex alone → `regexSearch`: **LIKE-prefilter on the longest guaranteed literal run,
     then regex-filter candidates in Swift.** The prefilter must only use a literal that
     EVERY match contains: escaped classes (`\d`) break runs, quantifiers truncate the
     run's last char, quantified groups discard their runs, any `|` or `(?` in the
     pattern disables the prefilter (full scan). Non-ASCII literals also disable it
     (SQLite `lower()` folds ASCII only). Getting this wrong silently hides results.
   - literal name queries (single AND-group, no negation/wildcards/slashes/Match Path/whole-word)
     → substring matching, including punctuation and mid-token fragments. Optional packed
     memory cache accelerates these; disk mode streams rows with identical matching rules.
   - simple whole-word queries → FTS fast path (`ftsQueryFor`)
   - filename-only boolean/wildcard queries (`|`, `!`, `*`/`?`) → `nameSearch`, using
     the packed memory cache or an equivalent disk scan with a compiled `NameQuery`
   - remaining whole-word queries, `/`-terms, Match Path → `scanSearch`
7. **Memory cache stores names and metadata, never full paths.** Validate it using the search
   connection's `PRAGMA data_version` inside the read transaction. Small local writes use
   a bounded, writer-lock-protected change journal; update hooks only record `entries` IDs.
   Include old IDs when an upsert changes the row ID. Pin the read snapshot before draining
   changes, with a nonblocking attempt at the writer lock. Fall back to a full load when
   the writer is busy, another connection has written, changes overflow, or compaction is
   needed. Cancelled partial patches must discard the cache. Release it in disk mode.
   Keep at most three lazy sort orders and merge changed rows into existing orders.
   Memory statistics estimate allocated array storage, not whole-process memory. ASCII searches compare packed bytes, Unicode
   searches retain Swift lowercase semantics. One completed candidate list can be reused
   for identical or provably narrower literal queries with unchanged filters. Invalidate
   it on cache patches/reloads; never publish partial cancelled candidates. Background
   cache/sort preparation uses the same serialized search connection and cancellation.
   Resolve paths only for returned rows when
   matching names. Keep disk and memory matching, counts, filtering, and sorting equivalent.
8. **Reads and writes use separate connections** (writer lock = `NSRecursiveLock`, reader
   for searches). WAL mode keeps readers unblocked during bulk inserts. Don't merge them.
   Searches use their own serialized connection and read transaction, separate from indexing
   reads. Cancellation interrupts SQL with a progress handler and checks Swift loops. Never
   publish cancelled or older-generation results, including when the query text repeats.
   Page with offsets and exact filtered totals. Only append pages with the same search
   connection data-version token; restart at page zero when the index changed.

## Indexing and journal lifecycle

- Full rebuilds and baseline reconciliation run on `IndexService.indexingQueue`.
  Cancel the old control before stopping its monitor/handler, then enqueue the new job.
  Cancellation must wake paused workers; never overlap old and new bulk-load jobs.
- Empty indexes rebuild. Existing indexes with a valid checkpoint replay missed events.
  Missing or invalid checkpoints trigger a full reconciliation, not an unconditional
  full walk on every launch.
- The sidecar is `index.sqlite.checkpoint`, next to the DB. It records the event ID,
  baseline time, DB device/inode identity, roots, exclusions, skip configuration, and
  mounted-volume journal identities. Validation rejects event-ID rollback, identity or
  configuration changes, and baselines at least seven days old. Seven days is a
  startup validation threshold, not a scheduled timer.
- Invalidate the checkpoint before a rebuild. Start monitoring before the baseline walk,
  suspend event application during that walk, then replay queued changes after it finishes.
  This covers changes made while the scan is in progress.
- Advance a cursor only after its batch has been successfully reconciled. Preserve retry
  work on errors. Ignore `HistoryDone` paths; the flag marks completion of replay.
- Ordinary directory events reconcile that directory and discover new subtrees using
  `scanKnownSubdirectories: false`. Do not rely on directory modification times to prove
  an entire existing subtree is unchanged. SQLite currently stores whole-second mtimes.
- `MustScanSubDirs`, root changes, and mount/unmount events require recursive handling.
  Dropped events or wrapped IDs force scans of all configured roots. Never discard flags
  when using the journal for correctness.
- `ChangeHandler` serializes ingest/application. Its stopped state rejects late callbacks.
  `FSEventsMonitor` owns a callback box rather than retaining itself through C context;
  invalidation/release must work even when starting the stream fails.
- `IndexingControl` blocks workers cooperatively on an NSCondition. Resume preserves the
  in-memory walk; it is not a saved resume point across app termination. Final FTS
  preparation cannot pause. Keep cancellation checks outside held locks.
- Publish UI state on the main queue. Guard stale callbacks with the job's control.
  `indexRevision` refreshes searches after index changes; debounce those refreshes.
- During reconciliation, remove an encountered name from the deletion candidate map
  whether it changed or not. Updating it and then treating it as vanished deletes valid results.

## Fragile interop details (learned the hard way)

- **FSEvents delivers directory paths with a trailing slash** (and canonicalizes
  `/var` → `/private/var`). Strip trailing slashes and map canonical event paths back
  to configured root paths. `Walk.canonicalPath` uses POSIX `realpath`; Foundation's
  path normalization is not a substitute. Cache root mappings before roots disappear.
- **FTS5 syntax**: adjacent parenthesized groups are NOT implicitly ANDed — join with
  explicit `AND`. Column-filter + phrase + star is `name : "tok"*`; bare `tok*` is
  preferred now that FTS is name-only.
- **`getattrlistbulk` buffer layout** (verified by hexdump, see `DirectoryReader.parseEntry`):
  `[u32 entryLength][attribute_set_t (5×u32, 20 bytes)][NAME attrref (u32 offset relative to
  the attrref itself + u32 length)][u32 vtype][timespec crtime][timespec mtime][off_t size
  (files only)]`. Attributes appear in ascending bit order; `ATTR_CMN_RETURNED_ATTRS` is
  0x80000000 (last). `getattrlistbulk` returns **Int32**.
- **NSStatusItem with both `action` and `menu`**: setting `menu` makes every click open the
  menu. For left-click-open/right-click-menu, leave `menu` nil and pop it manually
  (`statusItem.menu = menu; button.performClick(nil); statusItem.menu = nil`).
- **Window activation** uses the single SwiftUI `Window("Everywhere", id: "main")` scene.
  `MainWindowRegistration` captures `openWindow` from a View environment and registers
  the actual NSWindow with the delegate. Reuse it when available, deminiaturize it,
  and call `openWindow(id: "main")` when absent. Closed windows can remain in
  `NSApp.windows`; do not assume closing destroys the window or use title lookup.
- **Hotkey lifecycle**: configure and activate after window registration, not only in
  `App.init` or `applicationDidFinishLaunching`. Check both Carbon registration calls,
  validate signature and ID, remove the event handler on teardown, and surface errors
  through `HotKeyManager.registrationError`. Do not retain the hotkey owner through
  unmanaged callback data.
- **Menu checkmarks in `Commands`** require `@ObservedObject` on the model; plain `let`
  bindings set state but never re-render the menu.
- **TCC**: full-disk walks hit permission prompts for protected dirs (Mail, Safari…).
  Grant Full Disk Access for a complete index. `opendir` failures are counted as
  `skipped`, never fatal.
- The app's own DB directory is excluded from filesystem walks and monitor ingestion, including checkpoint
  writes. Ignored-only event batches must not write checkpoints, or they create a
  feedback loop. Explicit roots inside a default skipped prefix override that prefix
  in `IndexService.makeConfig`; retain the app's own index-directory exclusion.

## Testing conventions

- Committed tests are in `Tests/EverywhereCoreTests/` (XCTest); there is no UI test target.
  Use disposable local harnesses for AppKit/Carbon checks when needed. Distinguish
  registration/dispatch checks from an actual global-key or mouse interaction test;
  report when Computer Use permissions prevent the latter.
- `TestTree` (in `SearchAndDatabaseTests.swift`) builds parent-pointer hierarchies from
  path strings; use it for DB tests instead of hand-rolling `IndexRow`s.
- Tests always create isolated temp DBs — never touch the real
  `~/Library/Application Support/Everywhere/index.sqlite`.
- FSEvents tests wait on expectations with generous timeouts; keep them tolerant.
  Test replay of changes made while the service is stopped, mandatory recursive scans,
  ignored-event feedback prevention, and checkpoint invalidation. Use isolated
  UserDefaults suites for service tests and stop monitors before fixture cleanup.
- Test pause/resume without restarting the walk, cancellation while paused, and
  replacement of a paused job. Never pause while holding a database or stats lock.
- Benchmarks exist as throwaway tests (synthetic trees, `CFAbsoluteTimeGetCurrent`);
  create, run, delete — don't commit long-running benches.

## Conventions

- Swift 5 language mode, macOS 13+ deployment target (SDK is much newer — prefer
  API available on 13, gate anything newer).
- No code comments unless the user asks; keep names self-documenting.
- App-side UI uses NSSearchField, reusable NSTableView cells, saved column layouts,
  and a Settings scene. Search modifiers are always-visible button toggles beside
  the search field and share the model bindings used by the Search menu.
- Indexing activity is a compact status-bar spinner with item count and Pause/Resume;
  a paused state uses a static pause icon. Do not invent a percent-complete value for
  a filesystem walk whose total is unknown.
- Update the README and user guide when changing controls, shortcuts, query syntax,
  build/install steps, or indexing behavior. Keep user steps separate from internals.
- The name is **Everywhere**; bundle id `app.everywhere.macos`; DB dir
  `~/Library/Application Support/Everywhere/`.
- Schema version lives in `Database.schemaVersion`; bump it and the outdated DB is
  deleted and reindexed on launch (index is a cache — never migrate it).

## Exclusion controls

- Keep legacy name-substring exclusions separate from whole-name wildcard patterns.
  Patterns support `*` and `?`; all other characters are literal, and matching ignores case.
- Exact folder exclusions include descendants using path-component boundaries, with
  configured and canonical paths. Do not confuse `/cache` with `/cache-other`.
- Apply exclusions to initial walks, reconciliation, root handling, and event ingestion.
  Leave excluded existing children in reconciliation's deletion map so they are pruned.
- Checkpoints include name patterns and excluded path prefixes. Old checkpoints without
  patterns represent an empty pattern list. Settings changes apply through a rebuild.
