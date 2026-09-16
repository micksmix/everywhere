# Search performance measurements

Measured September 15, 2026 on the development Mac using disposable synthetic indexes.
No real user index was opened or modified. These are local measurements, not latency or
memory guarantees for every disk, filename distribution, or folder depth.

## Earlier in-memory filename cache measurements

A release-build Swift harness created 1,000,000 files under one root. Names were
`project_<number>_unit.pas` every hundredth file and `project_<number>_source.swift`
otherwise. A `.pas` query returned 10,000 entries. Timings include matching, exact
counting, sorting, path reconstruction, and result construction; they exclude the UI's
90 ms typing debounce and drawing the table.

| Mode | Measured time |
| --- | --- |
| Disk streaming, four runs | 719.9–754.3 ms |
| Memory, first search including loading | 213.5 ms |
| Memory, three subsequent searches | 46.8–47.7 ms |

The process's resident memory increased by 74,924,032 bytes (about 75 MB, or 71.5 MiB)
after loading and searching the cache. This is incremental cache-related memory, not
total application memory. The test process also retained SQLite and test-runner memory.
Longer names, larger result sets, Unicode matching, and different allocators can change
these figures. Full paths are not cached. The first load and the first search after an
index update take extra time to refresh the cache.

ASCII matching uses packed UTF-8 bytes; non-ASCII names or terms use Swift's lowercase
matching rules. Memory and disk modes use the same literal substring semantics,
filters, result limits, and ordering. Regex, whole-word, wildcard, and path searches
continue through the SQLite-backed engines. Clearing a search uses the existing
index-backed recent-items query and shows up to 10,000 entries.

A separate cancellation check stopped an ongoing million-row disk query after 12.7 ms
with cancellation scheduled at 10 ms. Subsequent searches succeeded. A disposable
AppKit harness exercised native search-field cancel-button dispatch, restored empty-query
results, a new query, and twenty rapid query/clear/replacement cycles. This was
programmatic native-control verification, not a physical mouse/keyboard UI test.

## SQLite size

A separate SQLite fixture used 1,000,000 synthetic rows with the production columns,
parent/name unique index, size and modification indexes, and name-only external-content
FTS5. Both databases were optimized, vacuumed, and checkpointed before size measurement.
Only the FTS `columnsize` option differed. These timings measure SQL retrieval and
sorting, not full application searches or path reconstruction.

| Format | Database bytes | MiB |
| --- | ---: | ---: |
| Previous FTS format | 140,156,928 | 133.7 |
| `columnsize=0` | 130,129,920 | 124.1 |

Savings: 10,027,008 bytes, or **7.2%** of the whole database in this fixture.

| FTS query, 10,000-row limit | Previous timing | New timing |
| --- | --- | --- |
| Token prefix `pas` | 8.26–8.46 ms | 8.37–8.69 ms |
| Common token `source` | 78.09–80.47 ms | 78.97–79.76 ms |
| Phrase `report txt` | 65.25–66.24 ms | 66.03–66.62 ms |

The removed records contain token counts used by ranking functions; Everywhere does
not rank with BM25. Full positional detail is retained for phrase queries. No full-path
column, second FTS column, or FTS prefix index was added. Existing size and modification
indexes remain. See [SQLite's columnsize documentation](https://www.sqlite.org/fts5.html#the_columnsize_option).

Schema version 3 rebuilds older cached indexes on launch. This follows the project's
existing cache replacement policy. It does not migrate old indexes or alter user files.

Long-running benchmark harnesses were removed after measurement. Permanent tests cover
literal punctuation, mid-token and Unicode matches, mode parity, filtered counts and
limits, cache refresh after writes/deletions, cancellation recovery, concurrent regex
searches, and phrase searches after FTS updates.

## Fast sorting and incremental refresh

A later release-build test on the same Mac used one million names with the same
`project_<number>_…` pattern. Sizes repeated modulo 1,000 and modification times modulo
3,000, exercising tie-breaking. Results were limited to 10,000 displayed entries.
These measurements include matching, counting, ordering, and path reconstruction.

| Query / operation | Time |
| --- | ---: |
| First `.pas`, including cache load | 204 ms |
| Repeated `.pas`, 10,000 matches | 40 ms |
| First `project`, name order, 1,000,000 matches | 65 ms |
| Repeated `project`, name order | 18 ms |
| First `project`, size order | 248 ms |
| Repeated `project`, size order | 21 ms |
| First `project`, modification order | 213 ms |
| Repeated `project`, modification order | 20 ms |
| Update one file, refresh three orders, and return `project` results | 76 ms |

The file write itself took 1.4 ms. After the update, instrumentation reported one
full cache load and one incremental refresh: it did not reload all filenames. A
cancelled refresh recovered on the next search with the changed metadata intact.

Allocated array storage was approximately 86.6 MB for packed rows, filenames, spare
capacity, and ID lookup ordering, plus 8.0 MB per cached sort order (24.0 MB for three).
This is an array-storage estimate, unlike the earlier resident-memory delta, and does
not include the process's other allocations. Orders are created lazily for broad
queries and capped at three. This trades bounded extra memory for faster repeated
sorting. Small updates merge changed entries into existing orders. Large change sets,
external writers, a busy writer during snapshot coordination, or accumulated unused
cache space can trigger a full reload.

The change journal and sort orders are in memory only: the SQLite schema remains at
version 3 with no additional persistent table or index. The synthetic file measured
138,174,464 bytes; this fixture's metadata distribution differs from the earlier size
comparison, so those file sizes should not be compared as a format change.

## Immediate search and paging (September 15, 2026)

The UI no longer waits 90 ms before starting a search. It requests 200 rows, appends
pages near the end of the loaded rows, and rejects pages from a different database
snapshot. Counts include only matching, visible results; the empty root is excluded.
The UI timer now includes scheduling and publication, but excludes table drawing.

A disposable release XCTest fixture created 100,000 files named `report-<number>.txt`
under `/projects/group-<number modulo 100>/`. The following single-run comparisons
include matching, exact counting, sorting, and path reconstruction. The old and new
10,000-row columns use the same query sequence. The new first-page column runs after
warming the cache and name sort. These are synthetic results, not measurements of
physical keystroke-to-screen latency or a benchmark against Everything itself.

| Query | Before, up to 10,000 rows | After, up to 10,000 rows | After, 200-row first page |
| --- | ---: | ---: | ---: |
| `re` | 39.6 ms, cold | 41.2 ms, cold | 2.12 ms |
| `rep` | 18.5 ms | 19.6 ms | 1.55 ms |
| `report-9` | 19.6 ms | 19.6 ms | 2.27 ms |
| `report-99` | 3.52 ms | 2.18 ms | 0.58 ms |
| `*.txt` | 209.7 ms | 22.25 ms | 4.12 ms |
| `report-99 \| group` | 210.4 ms | 5.77 ms | 3.71 ms |

With one million files in the same layout, warm first pages took 17.1 ms for `re`,
12.1 ms for the narrowing query `rep`, 2.54 ms for `report-99`, 36.5 ms for `*.txt`,
and 35.5 ms for the OR query. Preparing a fresh memory cache and name sort took
202.6 ms; the subsequent `re` page took 17.5 ms and its second page took 0.40 ms.
Cold starts and broad scans still cost time; background preparation moves the initial
load off the typing path when it completes before typing begins.

At 100,000 files, the estimated allocated arrays grew from 8.32 MB to 9.90 MB for a
broad query. The difference is the retained completed candidate list, which avoids
rescanning or sorting for subsequent pages. At one million files, total estimated
cache arrays were 109.1 MB with a broad candidate list and one sort order. These are
capacity-based estimates, not process resident memory. Only one candidate list is
retained, and at most three sort orders; disk mode releases them. No schema, persistent
index, full-path storage, or file-indexing algorithm changed.

### What was adopted from Everything

Everything documents an in-memory database and persistent fast-sort indexes
([Indexes](https://www.voidtools.com/support/everything/indexes/)). Its developer
attributes the performance of versions 1.4/1.5, written in C, to tight loops and
keeping hot data in CPU cache
([developer's explanation](https://www.voidtools.com/forum/viewtopic.php?t=9863)).
It also documents evaluating faster search conditions before slower ones
([Search functions](https://www.voidtools.com/support/everything/search_functions/)).

Everywhere now applies those principles with packed UTF-8 filename matching,
background sort preparation, compiled boolean/wildcard queries, and cheap literal
conditions before regex conditions. ASCII wildcards use a byte matcher; Unicode and
line-break cases preserve Foundation regex behavior. Literal queries that provably
narrow the previous query filter its completed candidate list, preserving its sort
order. Paging identical queries reuses that list directly. Index changes invalidate
it. These are adaptations of documented principles, not a claim to reproduce
Everything's undisclosed internal query engine. No speculative SIMD or parallel
scan implementation was added without evidence that it would improve this workload.

Regex, whole-word, and path searches remain SQLite-backed. Regex candidates are now
filtered before paging rather than truncated early. Their latency can still be
higher, and exact counting still requires examining all relevant candidates.

A disposable native AppKit/SwiftUI harness verified first-page loading, scroll-driven
page append, repeated query replacement, snapshot-change restart, and clearing. Its
650-file query published in 0.77 ms. This was programmatic native-control testing,
not a physical keyboard/mouse interaction test. Permanent tests cover paging across
engines and sort directions, filtered totals, narrowing/refinement, cache invalidation,
Unicode/boolean parity, and byte-glob equivalence to ICU for ASCII control characters.
The long-running benchmark and UI harness were not added to the repository.
