# Live-update performance

## 2026-11-03: file edits without sibling scans

Measured with a disposable XCTest fixture on Mac16,5 (16 logical CPUs, 48 GiB RAM),
macOS 27.2 build 26B123, using `swift test -c release --filter MonitoringBenchmarkTests`.
No real user index or saved settings were used. The benchmark was removed afterward.

Each isolated folder contained 1,000 or 10,000 files and had an existing SQLite index.
For each mode, 25 synchronous event batches either left one file unchanged or alternated
its size between two and three bytes. File writes happened outside the timed section.
Directory mode sent an ordinary directory event; file mode sent an `ItemIsFile | ItemModified`
event. Both modes used the updated database implementation, so this comparison isolates
the benefit of avoiding sibling enumeration, not every improvement over an older release.

Mean reconciliation cost per batch:

| Siblings | Event | Directory wall ms | File wall ms | Directory CPU ms | File CPU ms |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1,000 | Unchanged file | 0.9801 | 0.0852 | 0.9558 | 0.0801 |
| 1,000 | Changed metadata | 1.0810 | 0.1300 | 1.0624 | 0.1296 |
| 10,000 | Unchanged file | 11.7065 | 0.1232 | 11.5020 | 0.0963 |
| 10,000 | Changed metadata | 11.7471 | 0.1637 | 11.5327 | 0.1454 |

At 10,000 siblings, changed-file batches were approximately **72× faster** and used
**79× less CPU time**. Each file-mode batch examined one item and no directories,
versus 10,000 items and one directory in directory mode. Both changed-metadata modes
wrote 25 rows over 25 batches; both unchanged modes wrote zero rows.

These are warm-cache synthetic reconciliation timings, not end-to-end notification
latency, idle-process CPU measurements, cold-disk results, or guarantees for every workload.
They exclude OS event delivery, the normal debounce/cooldown delay, checkpoint serialization,
and UI searches. The file-event path can deliver more notifications than directory-only
monitoring, so total workload savings depend on event volume and batching.

## Work avoided

- Production streams request file-level events and allow macOS latency batching.
- Ordinary file content/metadata events use a cached `(parent, name)` lookup plus `lstat`,
  rather than enumerating a potentially large parent directory.
- Creates, deletes, and renames collapse into parent-directory checks. This preserves
  exact filesystem names on case-insensitive volumes and handles remove/create replacements.
- Directory changes reuse the indexed tree. New or replaced directories and mandatory
  recovery events still receive recursive checks; missing ancestors are discovered without
  inserting unscanned placeholder directories.
- Identical upserts do not mutate SQLite. Metadata-only updates do not rewrite name-only
  FTS entries. Existing version-4 databases receive the selective trigger without rebuilding.
- Search revisions advance only when index entries actually changed, including deletions,
  metadata changes, and empty-directory changes. A successful retry still reports mutations
  made before a failed checkpoint save.
- An unchanged checkpoint is not rewritten after its first successful save. Processed-event
  or archived-history advances still persist, and failed first saves remain retryable.
- Debounce deadlines cannot slide indefinitely under continuous arrivals. Pending paths are
  bounded at 16,384 keys; overflow becomes recursive recovery of all covered roots, retaining
  the oldest unprocessed event boundary. Overlapping recursive paths share one walk.

No full paths, additional persistent search indexes, FTS prefix indexes, schema-version
change, or periodic full-tree polling were added.

## Correctness coverage

Regression tests cover wide-folder point updates, no-op entry generations, filename changes
and case-only remove/create sequences, missing ancestors, file/directory/symlink replacements,
configured-root disappearance and return, `/` recovery, recursive overlap, pending overflow,
continuous arrivals, checkpoint retry behavior, exclusions, and real file-level FSEvents delivery.
Database tests also verify FTS stability for metadata-only updates and incremental memory-cache
correctness when row IDs change.

For enabling monitoring and expected freshness, see [the user guide](USER_GUIDE.md#manage-live-updates-and-startup-checks).
