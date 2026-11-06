# Live-update performance

## 2026-11-04: bounded scan CPU and stable recovery

Measured on the same Mac16,5 using a disposable release-mode XCTest fixture before
and after the scan/recovery changes. The tree had 40 groups containing 2,000 leaf
directories and 8,000 files (10,041 indexed rows including the root). Both runs used
real local-volume access validation, isolated SQLite databases, and warm filesystem
caches. CPU time is process user plus system time from `getrusage`; wall time uses
`ProcessInfo.systemUptime`. Fixture creation was outside the timed sections.

| Work | Before wall s | After wall s | Before CPU s | After CPU s |
| --- | ---: | ---: | ---: | ---: |
| 4,000 location validations | 0.262 | 0.219 | 0.169 | 0.157 |
| Initial indexing | 0.367 | 0.301 | 1.974 | 0.409 |
| Three unchanged full reconciliations | 0.985 | 0.812 | 5.838 | 1.152 |

Initial indexing used **79% less CPU time**; unchanged reconciliation used **80% less**.
Both were also faster in elapsed time on this fixture. Directory enumeration now uses
at most two workers instead of one dispatch iteration per directory, reducing parallel
filesystem work and shared-reader contention. Per-directory volume identity guards
read the local filesystem UUID directly instead of querying the FSEvents daemon;
checks before and after enumeration, including replacement detection, remain in place.
Journal UUID validation for persistent checkpoints is unchanged.

A separate isolated service fixture with live FSEvents monitoring enabled consumed
0.0107 CPU seconds during 6.030 wall seconds after startup settled (about 0.18% of one
CPU core). This short observation includes a location-availability poll; it is not a
long-running measurement of the user's app, UI searches, a full-disk scan, remote
volumes, or sustained filesystem churn. Results are single synthetic measurements,
not a universal CPU ceiling: two directory workers do not cap all process activity.
The throwaway benchmark was removed afterward.

Service regression tests also cover unchanged attempted topology after failure,
newer topology/access/configuration changes, overdue scheduled checks after failure,
explicit retry, preserving targeted live-update work across a checkpoint error, and keeping
one volume's successful commit from clearing another volume's failure or monitoring warning.
Unchanged availability polls no longer escalate those failures into repeated full scans.

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

### Repeatable operation budgets — November 5, 2026

The six [indexing performance regressions](../Tests/EverywhereCoreTests/IndexingPerformanceTests.swift)
run with `make test` or the release-mode `make test-performance` target. They use
isolated temporary trees of at most 192 files and synthetic batches of up to 2,048
events, exercising real batching/reconciliation without sleeps or live FSEvents streams.
Assertions budget unique point checks, scanned directories/items, row writes/deletions,
search snapshot changes, and incremental/full cache refreshes. Duplicate replay and
unchanged bulk/POSIX directory walks must not write or invalidate the search cache.
Other budgets cover overlapping recursive events, new-subtree discovery, unrelated
branches, and pending-overflow recovery across multiple roots. These budgets passed
without indexing implementation changes; they guard against future work amplification,
not absolute CPU or I/O latency. See [search measurements and remaining hotspots](SEARCH_PERFORMANCE.md#performance-regression-coverage--november-5-2026).

For enabling monitoring and expected freshness, see [the user guide](USER_GUIDE.md#manage-live-updates-and-startup-checks).
