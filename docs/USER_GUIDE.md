# Everywhere user guide

[Project overview and installation](../README.md)

The Homebrew release includes native Apple Silicon (ARM64) and Intel (x86_64)
binaries in one app for macOS 13 or later. Maintainers can find the automated
build and tap setup in [How to release](../README.md#how-to-release).

Choose **Help → Everywhere Help** or press **⌘?** to open this guide in macOS Help Viewer.
The installed app includes offline help, installation information, performance notes,
and the Apache License 2.0 text. When running with `make run`, Help opens the online guide.
Choose **Everywhere → About Everywhere** for license information and the
[project website](https://github.com/micksmix/everywhere).

## Common tasks

- [Open or return to Everywhere](#open-or-return-to-everywhere)
- [Find a file or folder](#find-a-file-or-folder)
- [Use search modifiers](#use-search-modifiers)
- [Search with patterns](#search-with-patterns)
- [Open, reveal, or copy results](#open-reveal-or-copy-results)
- [Choose indexed folders](#choose-indexed-folders)
- [Exclude names](#exclude-names)
- [Pause and resume indexing](#pause-and-resume-indexing)
- [Manage live updates and startup checks](#manage-live-updates-and-startup-checks)
- [Rebuild the index](#rebuild-the-index)
- [Troubleshoot missing results or shortcuts](#troubleshoot-missing-results-or-shortcuts)
- [Keyboard shortcuts](#keyboard-shortcuts)

## Open or return to Everywhere

Launch Everywhere from Applications, or from the app bundle you built.
Everywhere stays in the menu bar when all its windows are closed. While a search or
Settings window is open, it appears in the Dock and **⌘Tab** app switcher, and its
normal menus appear at the top of the screen when Everywhere is active. Closing the
last window removes the Dock and app-switcher entries.
While the app is running, press your global shortcut (default: **⌥Space**) or click its menu-bar icon.
A double-click also works. Everywhere brings its existing window forward, restores it
if minimized, or creates a window if one is unavailable.

Closing the window keeps the app running. To quit, use **⌘Q** or right-click the
menu-bar icon and choose **Quit Everywhere**. The shortcut works only while the app is running.

To start automatically when you log in to your Mac, open the installed app and enable
**Settings → General → Startup → Launch on Startup**. You can open **Settings…** by
right-clicking the menu-bar icon. If approval is needed, click **Open Login Items…**
and allow Everywhere in macOS System Settings. Turn the toggle off to stop launching
at login. The toggle refreshes when you return from System Settings. This option is
unavailable when running the unbundled executable with `make run`.

Open **Everywhere → Settings… → General** to toggle **Enable global shortcut** or change
the shortcut. Choose Space, a letter, or a digit and select modifiers (at least Control,
Option, or Command). Changes apply immediately and are saved across launches.
Use **Reset to ⌥ Space** to restore the default. Keys refer to their US keyboard positions.

## Find a file or folder

1. Press **⌘F** to focus the search field.
2. Type a name, such as `report`. Searching starts immediately as you type.
3. Choose **All**, **Folders**, or **Files** beside the search controls.
4. Click a result column heading to sort the search results; click again to reverse the order. The column and direction are saved across launches.
5. Drag column boundaries to resize them. The app saves the column layout.

Simple name searches match literal fragments anywhere in a name: `port` finds
`report.pdf`, and `.pas` finds names containing `.pas`, including the dot.

The table loads 200 results initially and adds pages as you scroll. The status bar shows
loaded rows, the full match count, and request-to-publication time (excluding table drawing).
Clearing the search with its **×** button or **⌘K** returns to recently modified items. This empty-search view
uses modification order and respects the All/Files/Folders filter; use a nonempty query
when applying other result sorting.

Everywhere searches names and paths, not the text inside documents.

## Use search modifiers

These buttons are beside the search field. Click to switch an option on or off;
the Search menu controls the same options.

| Button | Effect |
| --- | --- |
| **Aa** | Match case: distinguish `Report` from `report` |
| **Word** | Match whole words in ordinary text searches instead of word prefixes or partial words |
| **Path** | Match against the full path, including containing folders |
| **.\*** | Interpret the entire query as a regular expression |
| **Hidden** | Include names beginning with a dot, such as `.gitignore` |

Case, whole-word, path, and regex matching start off disabled. Hidden names start off
included. The Hidden control filters the item's own name; it does not promise to hide
every descendant of a hidden folder.

For example, turn on **Path** and search for `Invoices` to match files whose paths
contain that folder name. If a search behaves unexpectedly, check the active modifiers.

## Search with patterns

Keep **.\*** off for the ordinary query examples below.

| Query | Use |
| --- | --- |
| `report` | Find a word beginning with `report` in a filename |
| `annual report` | Require both terms |
| `"annual report"` | Keep words together as one phrase term |
| `report \| invoice` | Match either group of terms |
| `report !draft` | Match `report` and exclude `draft` |
| `*.pdf` | Match filenames ending in `.pdf` |
| `*budget*` | Find `budget` anywhere in a filename |
| `photo-??.jpg` | Match exactly two characters between `photo-` and `.jpg` |
| `/Users/alex/Documents/` | Find paths under that absolute directory; replace it with your own path |

`*` matches zero or more characters; `?` matches one character. Wildcard patterns
match the entire target, so include surrounding stars when searching for a fragment.
With **Path** enabled, the target is the entire path rather than just the name.
A term containing `/` also uses path matching even when the Path button is off.
A trailing slash on a non-wildcard path term means a path-prefix search.

Whitespace combines terms with AND, and `|` separates alternative groups. Parentheses
are not a grouping feature of the ordinary query language. Plain name queries use literal
substring matching. Add wildcards or enable Word to express a more specific match.

### Regular expressions

1. Turn on **.\***.
2. Enter a regular expression, for example `^report-\d{4}\.pdf$`.
3. Turn on **Aa** for case-sensitive matching, or **Path** to apply the expression to full paths.
4. Turn **.\*** off before returning to ordinary queries.

That example matches names such as `report-2026.pdf`. In regex mode, `^` and `$` anchor
the start and end, `\d{4}` matches four digits, and `\.` means a literal dot.
Ordinary wildcard syntax such as `*.pdf` is not a valid substitute for a regex.
The Word button does not add boundaries to a regex; express those in the pattern itself.
Invalid expressions produce an error in the status bar.

## Open, reveal, or copy results

Select one or more rows with the usual macOS selection gestures: **⌘-click** for
individual rows or **Shift-click** for a range.

| Task | Action |
| --- | --- |
| Open with the default app | Double-click, press Return, or use **⌘O** |
| Show Finder’s Info window | **⌘I**, or right-click → **Get Info** |
| Reveal in Finder | **⌘R**, or right-click → **Show in Finder** |
| Choose another app | Right-click a single result → **Open With** |
| Open a directory in Terminal | **⌥⌘T**, or right-click → **Open in Terminal** |
| Copy the full path | Right-click → **Copy Path** |
| Copy just the filename | Right-click → **Copy Name** |

Open in Terminal uses Terminal.app by default. In **Settings → General → Terminal**,
click **Choose Application…** to select another terminal. The choice is saved and applies
immediately. **Use Default** restores Terminal.app. The selected application must support
opening folder URLs. Launch errors are shown in an alert.

For a file, Open in Terminal uses its containing directory. Copied names or paths from
multiple selections are separated by newlines. Open actions handle up to ten items at
once; Open in Terminal handles up to five. With no explicit selection, keyboard open
and reveal actions use the first result. **Get Info** opens Finder’s own information
windows for up to ten selected files or folders, or the first result if nothing is
selected. It is also available in the **Search** menu and leaves your clipboard unchanged.

## Choose indexed folders

1. Open **Everywhere → Settings…** with **⌘,**.
2. In the **Locations** tab, under **Index Locations**, click **Browse…**, choose folders, and confirm.
   Alternatively, enter a path in **Add a folder to index…** and click **Add**.
   `~` expands to your home directory when using the text field.
3. Remove unwanted locations with the minus button.
4. Choose **Rebuild Index** under **Indexing → Maintenance** once the current operation is finished.

On first launch, choose **Home folder** (recommended), **Entire Mac**, or **Choose folders**,
then click **Start Indexing**. No scan begins before this choice. Home includes `~/Library`.
Entire Mac indexes accessible files under `/`. Existing installations keep their locations.
An empty saved location list stays empty; add a folder to resume indexing files.

We recommend **Full Disk Access** for more complete results and fewer permission prompts,
even when indexing only Home. Everywhere indexes filenames and metadata, not file contents.
At launch, an empty or newly created index triggers a protected-file access check before
indexing. If access is denied, a separate **Allow Full Disk Access** dialog appears before
location setup. A populated index skips this check. The dialog offers **Check Again** and
**Continue with Limited Access**; continuing dismisses it for this launch only.

Use **Open Full Disk Access Settings** in this dialog or in **Settings → Locations** to open
**System Settings → Privacy & Security → Full Disk Access**. Enable Everywhere; if it is
missing, click **+** and add Everywhere from Applications. Quit and reopen the app afterward.
If you already scanned, choose **Reindex Accessible Files** in **Settings → Locations**
when the current operation finishes. Without access, you can still search accessible files,
but protected files may be missing and macOS may ask for folder access. Access remains
subject to macOS permissions, mounted volumes, and index exclusions.

macOS has no public Full Disk Access status API. Everywhere uses a read-only access probe
without reading file contents. Missing probe files and ordinary filesystem permission
errors are inconclusive and do not trigger the launch dialog. You can always open the
access settings manually from **Settings → Locations**.

## Exclude names

1. Open **Settings… → Locations → Exclusions**.
2. Enter text such as `node_modules` or `cache` and click **Add**.
3. Rebuild the index to apply the change to the existing results.

Exclusions are case-insensitive name fragments, not glob patterns. `cache` can exclude
both `cache` and `ImageCache`; `*.tmp` is not interpreted as a wildcard exclusion.
Excluding a directory also prevents its contents from being indexed during a rebuild.
Remove an exclusion with its minus button, then rebuild to include those items again.

## Pause and resume indexing

Files appear automatically as indexing progresses, even with the search field empty.
You can search immediately; results refresh as more files become available.

When a saved index contains entries, the status bar shows **Indexing in 0:02:00** by default. Search the saved index
while you wait. **Pause** freezes the remaining time; the same button becomes **Resume**
and starts indexing immediately, skipping the remaining delay. Closing and reopening the window does not restart the timer.
Quitting and relaunching starts a new countdown.

In **Settings → Indexing**, enter a startup delay and choose **Seconds**, **Minutes**, or
**Hours**. Zero starts immediately; the maximum delay is 365 days. Editing the delay during
a countdown resets its remaining time to the new value, preserving pause for a nonzero delay.
**Rebuild Index** bypasses the delay.

Turn off **Enable indexing** to stop scans, catch-up, and live updates. The setting persists
across launches, and saved results stay searchable (but may be stale). An in-flight filesystem
operation or final search preparation may finish before stopping. Re-enable indexing to start
a fresh countdown and catch up on changes. Empty indexes start building immediately when indexing is enabled.

While a scan is running, the status bar shows a small spinner, an item count, and **Pause**.
Click **Pause**, then **Resume** to continue from the same point. These controls are also
available in Settings and the Search menu.

Pausing is cooperative: the current filesystem operation may take a moment to finish.
The spinner becomes a static pause icon. Counts and folder/skipped details are available
by hovering over the indexing status.

Resume preserves work only while the app stays open. Quitting does not save the active
walk for later resumption. The final **Preparing search…** step cannot pause.
The spinner indicates activity, not a percentage or an estimated finish time.

## Manage live updates and startup checks

Click **Live Updates** in the window's bottom status bar to toggle monitoring. The button
is selected when live updates are enabled and is unavailable while indexing is disabled.
The same setting is available in **Settings… → Indexing → Live Updates → Watch the file system for changes**.
Turn it on to keep the index up to date while Everywhere runs. Turn it off to stop ongoing monitoring after any current
startup catch-up finishes. This setting is separate from pausing an active scan.

At startup, Everywhere catches up on changes recorded while it was closed. A valid saved
checkpoint lets it check changed directories instead of walking every file again.

A full check can still occur when:

- This is the first run, or there is no usable checkpoint.
- Index locations, exclusions, or other index configuration have changed.
- Volume or journal identities have changed, or event history cannot be trusted.
- The last full-scan baseline is at least seven days old when the app starts.
- You explicitly rebuild the index.

The seven-day rule is checked at launch; it is not a scheduled weekly background job.
An upgrade from a version without checkpoints needs one full check to establish its baseline.

## Rebuild the index

Use **Search → Rebuild Index** or **Settings… → Indexing → Maintenance → Rebuild Index**.
Wait for the current operation to finish if the control is disabled.

A rebuild discards and reconstructs the search cache. It does not delete your files.
Results can be incomplete until scanning and search-index preparation finish.
Use a rebuild after changing locations or exclusions, granting access to protected
folders, or investigating persistent missing/stale results.

## Troubleshoot missing results or shortcuts

### A file is missing

1. Clear the query and review **Aa**, **Word**, **Path**, **.\***, **Hidden**, and the kind filter.
2. Try a simple filename fragment.
3. Check that its folder is covered by Index Locations and not excluded by name.
4. Confirm that its volume is mounted and the app has permission to read it.
5. Resume any paused scan and let index preparation finish.
6. Rebuild if results remain stale. Check **Settings… → Indexing → Maintenance** for an error message.

Hidden results depend on the item's dot-prefixed name. File contents are not searchable.
Some system locations are skipped by default. The status count is not proof that every
protected or excluded item was indexed.

### The global shortcut does nothing

1. Confirm Everywhere is running; look for its menu-bar icon.
2. Enable **Enable global shortcut** in Settings and check the configured shortcut.
3. Read any registration error shown below that setting.
4. If another app uses the shortcut, choose another key combination in Settings. Toggle Everywhere's
   option off and back on to retry registration.
5. Quit duplicate or older copies, then launch the version you installed or just built.

The menu-bar icon provides another way to bring the window forward.

### Startup is checking everything again

Review the full-check conditions above. A missing checkpoint after an interrupted first
scan, a configuration/volume change, or an old baseline can explain it. Allow one full
check to finish, then verify behavior on the next launch. Maintenance errors may indicate
that monitoring or checkpoint saving failed.

### Live results stopped changing

Enable Live Updates, finish or resume the startup scan, and check Maintenance for errors.
If the file was moved to an unindexed location or an unmounted volume, adjust the locations
or mount the volume. Rebuild if needed.

## Keyboard shortcuts

**⌘** = Command, **⌥** = Option, **⇧** = Shift. Except for the global shortcut, use these while Everywhere is active.

| Shortcut | Action |
| --- | --- |
| **⌥Space** (customizable) | Show/focus Everywhere while it is running and the shortcut is enabled |
| **⌘F** | Focus the search field |
| **⌘K** | Clear the search and focus the field |
| **⌘O** or **Return** | Open the selected item(s), or the first result |
| **⌘R** | Show selection in Finder |
| **⌘I** | Get Info in Finder for the selected item(s), or the first result |
| **⌥⌘T** | Open selection's directory in Terminal |
| **⌥⌘C** | Toggle Match Case |
| **⌥⌘W** | Toggle Match Whole Words |
| **⌥⌘P** | Toggle Match Path |
| **⌥⌘X** | Toggle Regular Expressions |
| **⇧⌘H** | Toggle Hidden Files |
| **⌘,** | Open Settings |
| **⌘W** | Close the window; keep Everywhere running |
| **⌘Q** | Quit Everywhere |

### Index storage location

In **Settings → Locations → Index Storage**, use **Choose Existing…** to select a saved
Everywhere index, or **New File…** to choose where to build a new one. You can also enter
an absolute file path and click **Apply**. Quit and reopen Everywhere to use the selected
file. This does not move or copy the current index. **Use Default** restores
`~/Library/Application Support/Everywhere/index.sqlite` for the next launch.
Use a dedicated folder: the index's containing folder is excluded from indexing.

If the saved index cannot be opened, a notice explains that Everywhere is using a
temporary index for this session. Your saved location stays unchanged. Choose a writable
location in Settings before restarting. If temporary storage is also unavailable,
Everywhere shows an error and quits.

An incomplete directory read preserves its previously indexed entries. Permission
failures appear in the skipped count. Other read errors stop reconciliation and keep
the journal checkpoint from advancing; resolve the reported problem and restart to retry.

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

### Appearance

In **Settings → General → Appearance**, choose **System**, **Light**, or **Dark**.
System follows the macOS appearance; changes apply immediately and are saved.
The search window displays the Everywhere icon in its title bar.

### Deleted files

With live updates enabled, filesystem events trigger reconciliation that removes deleted
files and deleted folders’ descendants from search results. Changes made while the app
is closed are caught up during startup indexing after the configured delay. While
indexing or live updates are disabled, saved results can remain stale. Rebuild the index
if needed. Removing entries frees space for reuse inside the database; compaction
reclaims disk space separately, as described above.

Terminal quick-select buttons in **Settings → General → Terminal** find **Ghostty**,
**iTerm2**, **Warp**, **kitty**, or Apple **Terminal**. They check system and user
Applications folders, Utilities folders, common Homebrew locations, and macOS’s
registered applications. A match saves and displays the application path immediately.
If no installation is found, a message appears and your current selection is retained.
You can still use **Choose Application…** to browse manually.

### Search memory and database format

**Settings → General → Search Performance → Keep filename index in memory** is on
by default. It speeds up plain filename, wildcard, OR, and negated searches by caching
packed names and metadata. The cache and selected sort order prepare in the background
while indexing is idle. Typing cancels background preparation when needed. Small file
changes apply incrementally; large changes, external database edits, or busy indexing
may reload the cache. Full paths are reconstructed only for each requested page.
Regex, whole-word, and path searches continue to use the SQLite search engines.

Turn the option off to release the cache and query SQLite directly. This uses less
active memory, but filename searches can be slower. The operating system and SQLite
still use their own caches; this option does not mean zero memory use. Choices apply
immediately and persist across launches.

Typing or clearing a query cancels obsolete work, and only the newest search updates
the table. Extending a plain query reuses previous matches when safe. Clearing it shows
recently modified items, also loaded in pages. If the index changes between pages,
the search restarts at its first page so rows from different snapshots are not mixed.

This version uses a smaller SQLite FTS format that omits unused token-count records
while preserving phrase searches. The schema change rebuilds older indexes on launch;
your files are unaffected. The new index must finish rebuilding before all results return.

### Fast sorting and memory usage

The selected sort order prepares in the background after searches while indexing is
idle; broad filename searches can also build it on demand. Up to three
column/direction combinations are kept; less-used orders are released. Selective
queries sort just their matches. The first broad query in a new sort order can take
longer while that order is prepared. Small file changes update existing sort orders.

**Settings → General → Search Performance** shows indexed cache items, filename-cache
storage, and fast-sort storage. These figures estimate allocated arrays, excluding
other app memory and temporary work. Turning memory indexing off releases the cache
and its sort orders through the next scheduled search.

### Exclude specific folders and name patterns

In **Settings → Locations → Excluded Folders**, click **Exclude Folder…** to choose one
or more folders. Each selected folder and its contents are excluded; a different folder
with the same name is unaffected. Remove an entry with its minus button.

In **Excluded Name Patterns**, enter patterns separated by semicolons, then click **Add**:

- `*.tmp; *.log` excludes names ending in `.tmp` or `.log`.
- `cache-?` excludes names such as `cache-a`, but not `cache-archive`.
- `scratch` excludes that exact name. Use the existing **Exclusions** section to exclude
  any name containing a word instead.

Patterns ignore case and match whole names. `*` matches any text and `?` one character;
other symbols are literal. Matching folders and their descendants are also excluded.

Use **Search → Rebuild Index** after adding or removing exclusions. The rules then apply
to the initial scan and live updates. The app's index-storage folder is always excluded.

Indexes from earlier versions are rebuilt once on launch to remove duplicate paths created by folder updates. Live updates now reuse the existing indexed folder tree.
