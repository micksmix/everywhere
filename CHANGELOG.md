# Changelog

## 1.3.0

- Replace the Live Updates button with a switch that shows whether the file system is actually being watched and starts or stops watching immediately, independent of indexing scans and the startup delay.
- Center the app icon next to the Everywhere name in the main window's title bar.
- Ask before quitting whether to quit or minimize to the menu bar; enable Settings → General → Quitting → Always quit without asking to quit immediately.

## 1.2.0

- Make the main search window behave like a normal macOS window instead of staying above other windows.
- Speed up metadata-filtered filename searches such as `type:image vacation` by using the packed filename cache and SQLite literal prefilters while preserving exact counts, sorting, pagination, and disk/memory result parity.
- Make built-in indexing exclusions visible in Settings, including `/System/Volumes`, with individual remove controls, persistent changes, and a Restore Built-in Exclusions action. Explicit index locations can override built-in path exclusions; the app's own index folder remains a protected exclusion.
- Reorganize Settings into a sidebar with focused detail panes for general preferences, shortcuts, terminal selection, updates, search performance, indexing, locations, custom exclusions, built-in exclusions, index storage, and file access.
- Expand search-performance and exclusion documentation, including why results can differ from other search tools when system-volume paths are excluded.

## 1.1.0

- Add signed GitHub release updates via Sparkle: check on startup, check manually, optionally install automatically, and relaunch after updating; controls are in Settings → General → Updates.
- Add search filters: `ext:`, `type:`, `file:`, `folder:`, `size:`, and `dm:` (date modified), combinable with name terms, phrases, wildcards, `!`, and `|` groups; quoted filter tokens stay literal.
- Add folder scopes with `in:` (all descendants) and `parent:` (direct children), plus fast trailing-slash path-prefix searches via recursive index traversal.
- Add Quick Look previews: Space toggles the panel, ⌘Y and a context-menu item open it for the selection; the preview refreshes as selection or results change.
- Add match highlighting in the name and path columns of result rows.
- Add search history: ↑/↓ navigates previous queries, searches are remembered on open/reveal, and Help menu clears history; history persists between launches.
- Redesign the search row: search field, always-visible modifier toggles, kind filter, and a help button now sit in a row above the results instead of the toolbar.
- Add an offline Help window (WebKit) with Find on Page, Back/Forward navigation, and a Search Syntax entry; add a native help button with transient syntax-tips popover; generated help now embeds images.
- Speed up memory-cache searches: shared storage for duplicate names, ASCII character rejection masks, 32-bit cache positions, and reuse of repeated-name match decisions (19–42% lower median search times in benchmarks).
- Document filters, scopes, highlighting, history, and Quick Look in the user guide; record new benchmark results.

## 1.0.0

- Initial release.
