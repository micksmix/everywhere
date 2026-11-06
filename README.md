# Everywhere

Instant file and folder search for macOS 13 and later. Everywhere is a native app
that indexes filenames and metadata, so you can find files without searching their contents.

![Everywhere search results](docs/everywhere-01.png)

## Features

- **Search as you type:** filename fragments, wildcards, regex, boolean queries, and path matching.
- **Useful filters:** files or folders, extension, type, size, modification date, and folder scope.
- **Saved scopes:** fast index-only filtering of named folder sets and reusable search expressions, with pinned favorites and a default scope.
- **Offline volumes:** classify local, network, and removable locations; optionally retain disconnected indexes and refresh them on reconnection.
- **Native results:** sortable columns even before searching, saved layouts, highlighted matches, and Quick Look previews.
- **File actions:** open, reveal in Finder, Get Info, Open With, Open in Terminal, and copy names or paths.
- **Easy access:** menu bar icon that toggles between opening/restoring and minimizing the window, recordable global shortcut including punctuation (default **⌥Space**), and launch at login.
- **Fresh results:** low-overhead, batched file-level live updates, catch-up after the app was closed, and optional daily, weekly, or monthly full checks. Live Updates switches remember your choice during startup and scans.
- **Indexing controls:** choose folders and exclusions, pause or resume scans, and search the saved index immediately. Background scans use limited parallelism instead of saturating every CPU core.
- **macOS conveniences:** search history, offline help, light/dark appearance, and built-in updates.

## Install

Install the latest release into `/Applications`:

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

### Build from source

Requires Swift 5.9+, Apple's macOS build tools, Python 3, and
[Pandoc](https://pandoc.org/installing.html) (`brew install pandoc`).

```sh
make test
make app
open .build/Everywhere.app
```

Use `make install` to build and copy the app to `/Applications`.

For contributors, `make test-performance` runs the small search/indexing performance
regressions in release mode. They also run with `make test` and assert work/storage
budgets rather than machine-specific timings. See [performance coverage and known hotspots](docs/SEARCH_PERFORMANCE.md#performance-regression-coverage--november-5-2026).

## First use

1. Choose **Home folder**, **Entire Mac**, or specific folders to index.
2. For complete results, grant **Full Disk Access** in **Settings → File Access**, then quit and reopen Everywhere.
3. Type a filename fragment. Press **Return** to select the first result, use **↑/↓** to navigate, then press **Return** again to open. Double-click also opens; **Space** in results shows Quick Look.

Try `report ext:pdf`, `type:image size:>10MB`, or `in:~/Documents dm:pastweek`.
Click **?** beside the search field for syntax tips.

## Documentation

- [User guide](docs/USER_GUIDE.md): setup, search syntax, shortcuts, and troubleshooting.
- [Changelog](CHANGELOG.md): release changes.
- [Search performance](docs/SEARCH_PERFORMANCE.md): measurements and limitations.
- [Live-update performance](docs/MONITORING_PERFORMANCE.md): monitoring benchmarks and safeguards.
- [Contributor guide](AGENTS.md): architecture and development workflows.
- [Release guide](docs/RELEASING.md): builds, publishing, signing, and Homebrew tap setup.
- [Website guide](docs/WEBSITE.md): preview and publishing.

## Credits and license

Inspired by [Everything](https://www.voidtools.com/) and
[FSearch](https://github.com/cboxdoerfer/fsearch); independently implemented for macOS.
Licensed under [Apache 2.0](LICENSE).
