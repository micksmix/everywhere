# Everywhere

Everywhere is a native macOS file-search app. Search file and folder names, narrow
results with path and pattern matching, and open items directly from a native results table.

It indexes names and filesystem metadata, not document contents.

## Features

- Search as you type, with case, whole-word, path, regex, and hidden-file controls beside the search field.
- All, Folders, and Files filters; sortable results and saved column layouts.
- Open files, reveal them in Finder, choose an application, open a directory in your default terminal, and copy names or paths.
- Runs in the menu bar when its windows are closed; open windows have normal app menus, a Dock icon, and a ⌘Tab entry. Includes a configurable global shortcut (default: **⌥Space**; change it in **Settings → General**).
- Optional **Launch on Startup** in **Settings → General → Startup** opens Everywhere automatically when you log in. Enable it from the installed app; if macOS requests approval, use **Open Login Items…**.
- Search the saved index on launch, with a configurable 120-second indexing countdown.
- Pause/resume the countdown or scan, or disable indexing entirely in Settings.
- Live filesystem updates with a status-bar toggle, and journal replay to catch changes made while the app was closed.
- Configurable index locations and name-based exclusions.

## Requirements

- macOS 13 or later.
- To build: a Swift 5.9 or newer toolchain, a macOS SDK, and Apple's command-line build tools.
  The package uses Swift 5 language mode.
- To bundle the offline Help book: Python 3 and [Pandoc](https://pandoc.org/installing.html) (`brew install pandoc`).
- SQLite and the macOS frameworks supplied by the operating system; no third-party Swift packages are required.

## Build and launch

From the project directory:

```sh
make test
make app
open .build/Everywhere.app
```

The app bundle is signed ad hoc for local use. This build workflow does not notarize it.

To install in Applications, quit any running copy first, then run:

```sh
make install
open /Applications/Everywhere.app
```

`make install` rebuilds the app and replaces `/Applications/Everywhere.app`.
Run only one copy when testing the global shortcut.

| Command | Purpose |
| --- | --- |
| `make test` | Run the XCTest suite |
| `make build` | Compile a release build |
| `make app` | Build and sign `.build/Everywhere.app`, including its icon and offline Help book |
| `make install` | Build and copy the app to Applications |
| `make open` | Install and launch |
| `make run` | Run the debug executable from the terminal |
| `make clean` | Remove build artifacts; the user index remains separate |

## First use

1. Open Everywhere and choose **Home folder** (recommended), **Entire Mac**, or **Choose folders** before the first scan. Home includes `~/Library`. Existing installations keep their locations.
2. If the index is empty and protected file access is denied, a separate **Allow Full Disk Access** dialog appears before indexing. Use **Open Full Disk Access Settings**, enable Everywhere, then quit and reopen it. **Check Again** retries the check; **Continue with Limited Access** proceeds with accessible files.
3. Choose **Rebuild Index** after changing locations or exclusions. Let any current operation finish first.
4. Type a filename or word from its name. Try `report`, or `*.pdf` for PDF filenames.
5. Select a result and press **⌘O**, or double-click it, to open it.

Full Disk Access gives more complete results and fewer permission prompts. The same settings button is available in **Settings → Locations**. Enable Everywhere (use **+** to add it from Applications if needed), then quit and reopen the app. If already scanned, choose **Reindex Accessible Files** there. Everywhere indexes filenames and metadata, not file contents. See the
[user guide](docs/USER_GUIDE.md) for setup, search examples, and troubleshooting.

## How indexing works

Files appear automatically as indexing progresses, even with the search field empty.
You can search immediately; results refresh as more files become available.

The initial walk uses `getattrlistbulk` with a POSIX fallback. SQLite stores a compact
parent/name tree and an FTS5 index on names; full paths are reconstructed for results.

Indexing waits 120 seconds after launch by default. Change the delay in **Settings → Indexing**
using seconds, minutes, or hours. **Pause** freezes the countdown; **Resume** starts indexing immediately.
Disable **Enable indexing** to keep using the saved index without updates. **Rebuild Index**
bypasses the countdown when indexing is enabled. An empty index starts building immediately, skipping the delay when indexing is enabled.

Normal subsequent launches use a saved FSEvents checkpoint to reconcile changed
directories. A full check is needed when no valid checkpoint exists, the configuration
or volume identities change, the journal cannot be trusted, or the baseline is at least
seven days old. The seven-day check occurs at startup, not on a background schedule.
The first launch after upgrading from a version without checkpoints also needs a full check.

The index and checkpoint live in:

```text
~/Library/Application Support/Everywhere/
  index.sqlite
  index.sqlite.checkpoint
```

SQLite may also create WAL and shared-memory companion files. Preferences are stored
separately in UserDefaults. Rebuilding replaces the index cache, not the indexed files.

## Documentation and development

- [User guide](docs/USER_GUIDE.md): everyday tasks, search syntax, shortcuts, and troubleshooting.
- [Contributor guidance](AGENTS.md): source layout, architecture constraints, and testing requirements.
- [Icon design](Resources/AppIcon-design.md): the vector artwork and menu bar adaptation.

Core logic is in `Sources/EverywhereCore`; SwiftUI and AppKit code is in
`Sources/Everywhere`. Tests live in `Tests/EverywhereCoreTests` and use isolated databases.
Run `make test` before finishing a change and keep builds free of warnings.

The icon source is `Resources/AppIcon.svg`. The build renders each ICNS size directly from the vector artwork and regenerates the bundle when
the source or `Scripts/make-icon.swift` changes.

### Index storage location

In **Settings → Locations → Index Storage**, use **Choose Existing…** to select a saved
Everywhere index, or **New File…** to choose where to build a new one. You can also enter
an absolute file path and click **Apply**. Quit and reopen Everywhere to use the selected
file. This does not move or copy the current index. **Use Default** restores
`~/Library/Application Support/Everywhere/index.sqlite` for the next launch.
Use a dedicated folder: the index's containing folder is excluded from indexing.

If the saved index cannot be opened, Everywhere explains the problem and uses a temporary
index for the session. Choose a writable location in Settings before restarting. If a
temporary index also cannot be created, Everywhere shows the error and quits.

Reconciliation preserves saved entries when a directory cannot be read completely.
Permission failures are counted as skipped; other read errors stop reconciliation so
the journal checkpoint does not advance past failed work.

The active path is shown in Settings; **Show in Finder** reveals that file. The saved
item count loads independently of the startup countdown. A loading message or read
error is shown separately from a confirmed empty index. If a saved database has no
entries, indexing starts immediately when enabled. You can also choose another existing index.

### Database compaction

To reclaim unused space immediately, open **Settings → Locations → Index Storage** and
click **Compact Index Now**. This compacts the active index without rebuilding it and
shows a completion message. It works during the startup countdown or with indexing
disabled; wait for any running or paused scan to finish first. Manual compaction skips
the automatic size thresholds below and requires sufficient temporary disk space.

Everywhere checks for unused database space after indexing finishes and at most once an
hour while indexing is idle. It compacts the database when at least 128 MiB and 25% of
its pages are unused, provided sufficient temporary disk space is available. The status
shows **Compacting index…** while this runs. File updates may wait during compaction;
searches continue using the saved index. Checks are deferred while scanning, paused,
waiting for startup, or indexing is disabled.

The Settings window opens taller to show more options. Drag its edges or corners to resize it; its minimum size keeps controls readable.

### Appearance and terminal application

**Settings → General** lets you choose **System**, **Light**, or **Dark** appearance
and select a terminal application for **Open in Terminal**. Both choices are saved and
take effect immediately. Terminal.app is the default; custom terminals must support
opening folder URLs. The search window includes the Everywhere icon in its title bar.

Deleted files and folders are removed from the index when filesystem changes are
reconciled. Startup indexing catches up on changes made while Everywhere was closed.
Saved results may remain stale while indexing or live updates are disabled. Deleted
entries free database space for reuse; the compaction described above reclaims disk space.

Terminal quick-select buttons in **Settings → General → Terminal** find **Ghostty**,
**iTerm2**, **Warp**, **kitty**, or Apple **Terminal**. They check system and user
Applications folders, Utilities folders, common Homebrew locations, and macOS’s
registered applications. A match saves and displays the application path immediately.
If no installation is found, a message appears and your current selection is retained.
You can still use **Choose Application…** to browse manually.

### Faster filename searches

**Settings → General → Search Performance** includes **Keep filename index in memory**,
enabled by default. It caches packed names and metadata for substring, wildcard, OR, and
negated filename searches;
turn it off to use less active memory and query SQLite directly, which can be slower.
The cache and selected sort order warm in the background while indexing is idle, and
small index changes apply incrementally. Regex, whole-word, and path queries continue
to use SQLite. Full paths are not retained in the memory cache.

Searches start immediately as you type. The first 200 results appear before more rows
load as you scroll, with an exact match count and no 10,000-result table cap. Narrowing
a plain query reuses its previous matches when the index and filters are unchanged.
The status time measures request-to-publication latency, including scheduling, but not
table drawing.

Plain searches now preserve punctuation and find fragments anywhere in a name. Clearing the search with **×** or **⌘K**
restores the recent-items view, and newer searches cancel obsolete work.

The smaller FTS format requires a one-time index rebuild on launch. Benchmark details
and limitations are in [Search performance measurements](docs/SEARCH_PERFORMANCE.md).

### Sorting, memory usage, and exclusions

Broad filename searches reuse up to three cached sort orders. Small file updates patch
the cache and these orders; larger changes reload the cache. The table remembers the
selected sort column and direction across launches. **Settings → General → Search
Performance** shows estimated filename-cache and sort-array memory use.

**Settings → Locations** now includes **Excluded Folders** with a folder chooser and
**Excluded Name Patterns** such as `*.tmp; *.log`. Patterns match whole names; existing
substring exclusions still work separately. Rebuild the index after changing exclusions.

Indexes from earlier versions are rebuilt once on launch to remove duplicate paths created by folder updates. Live updates now reuse the existing indexed folder tree.

Select a result and press **⌘I**, or right-click → **Get Info**, to open Finder’s own
information window. Get Info is also in the Search menu and supports up to ten selected
files or folders without changing the clipboard.

### Built-in help and license

Choose **Help → Everywhere Help** (or **⌘?**) to read the user guide in macOS Help Viewer.
The bundled help works offline and includes the overview, installation steps, search
performance notes, and Apache License 2.0. `make app` regenerates it from the Markdown
documents, so documentation changes ship with the app. `make run` opens the online guide instead.

**Everywhere → About Everywhere** shows the Apache License 2.0 license and a link to
[the project on GitHub](https://github.com/micksmix/everywhere).
