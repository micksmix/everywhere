# Everywhere

Instant file and folder search, built for macOS. Find files as you type, narrow the
results, and preview or open what you need. Everywhere indexes **filenames and
metadata—not file contents**.

**macOS 13+ · Apple Silicon and Intel**

![Everywhere in light mode: report ext:pdf finds PDF reports, with matching names highlighted and results sorted by modification date](<docs/search-light.png>)

*Find a report by name and extension. Native app captures use an illustrative sample index.*

## Install

[Download the latest release](https://github.com/micksmix/everywhere/releases/latest),
unzip it, and drag Everywhere to Applications. Or install it with:

```sh
curl -fsSL https://raw.githubusercontent.com/micksmix/everywhere/main/Scripts/install.sh | sh
```

### Homebrew

```sh
brew tap micksmix/tap
brew trust micksmix/tap
brew install --cask micksmix/tap/everywhere
```

Update through **Everywhere → Check for Updates…** or Homebrew.
The app is signed ad hoc and is not notarized. If macOS blocks the first launch,
allow it in **System Settings → Privacy & Security → Open Anyway**.

## Your first search

1. Launch Everywhere and choose **Home folder**, **Entire Mac**, or specific
   folders to index.
2. For more complete results, grant **Full Disk Access** from **Settings → File
   Access**, then quit and reopen Everywhere. If you've already indexed, use
   **Reindex Accessible Files** in that pane.
3. Type a filename fragment. **Return** selects the first result; **↑/↓** moves
   through results. Press **Return** again to open, or **Space** for Quick Look.

Bring the window back with the menu bar icon or **⌥Space** while Everywhere is
running. The shortcut is customizable, and launch at login is optional.

### A few searches to try

| Search | Finds |
| --- | --- |
| `report ext:pdf` | PDF files with “report” in the name |
| `type:image size:>10MB` | Images larger than 10 MB |
| `in:~/Documents dm:pastweek` | Items in Documents modified in the past week |

Click **?** beside the search field for tips, or read the
[search guide](<docs/USER_GUIDE.md#find-a-file-or-folder>).

## Built for your workflow

- **Search your way.** Filename fragments, wildcards, regex, boolean queries, and
  path matching, plus filters for type, size, date, and folder.
- **Keep projects in reach.** Save named folder sets and search expressions as
  scopes, then pin favorites or choose a default. Switching scopes filters the
  index without starting a scan.
- **Do more from the results.** Sort columns, preview with Quick Look, open in
  another app or Terminal, reveal in Finder, and copy files, names, or paths.
- **Find files on disconnected drives.** Retain the last indexed metadata for
  removable and network volumes. Reconnect the drive to open or preview a file.
- **Control the background work.** Choose folders and exclusions, pause or resume
  scans, and search the saved index immediately. Live updates, startup catch-up,
  and optional scheduled checks keep supported locations current.

![Everywhere in dark mode: a pinned Photos scope and the native context menu with Open, Show in Finder, Quick Look, and copy actions](<docs/file-actions-dark.png>)

*Right-click a result for native file actions. With results focused, **⌘C** copies
files for Finder Paste; **⇧⌘C** copies their paths.*

## Build from source

Requires Swift 5.9+, Apple's macOS build tools, Python 3, and
[Pandoc](https://pandoc.org/installing.html) (`brew install pandoc`).

```sh
make test
make app
open .build/Everywhere.app
```

Use `make install` to build and copy the app to `/Applications`.
For contributors, `make test-performance` runs the search/indexing regression tests
in release mode. See [performance coverage and limitations](<docs/SEARCH_PERFORMANCE.md#performance-regression-coverage--november-5-2026>).

## Documentation

- [User guide](<docs/USER_GUIDE.md>): setup, search syntax, shortcuts, and troubleshooting. Also available offline from the app's Help menu.
- [Changelog](<CHANGELOG.md>): release changes.
- [Search performance](<docs/SEARCH_PERFORMANCE.md>) and [live-update performance](<docs/MONITORING_PERFORMANCE.md>): measurements, safeguards, and limitations.
- [Contributor guide](<AGENTS.md>): architecture and development workflows.
- [Release guide](<docs/RELEASING.md>) and [website guide](<docs/WEBSITE.md>): building and publishing.

## Credits and license

Inspired by [Everything](https://www.voidtools.com/) and
[FSearch](https://github.com/cboxdoerfer/fsearch); independently implemented for macOS.
Licensed under [Apache 2.0](<LICENSE>).
