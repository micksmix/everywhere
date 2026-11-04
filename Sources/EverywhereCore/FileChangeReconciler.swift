import Foundation

final class FileChangeReconciler: IndexEngine {
    func run(paths: [String], isCancelled: @escaping @Sendable () -> Bool) throws {
        var parents: [String: Int64] = [:]
        var fallback: [String: Bool] = [:]
        var deletes: [Int64] = []
        for path in paths.sorted() {
            if isCancelled() { return }
            if config.ignores(path: path) { continue }
            let parent = (path as NSString).deletingLastPathComponent
            let parentID: Int64
            if let cached = parents[parent] {
                parentID = cached
            } else if let ancestor = try db.indexedDirectoryAncestor(path: parent, roots: config.roots) {
                guard ancestor.path == parent else {
                    fallback[ancestor.path] = fallback[ancestor.path] ?? false
                    continue
                }
                parentID = ancestor.id
                parents[parent] = parentID
            } else {
                if let root = config.roots.filter({ IndexedVolume.contains($0, path) })
                    .min(by: { $0.count < $1.count }) {
                    fallback[root] = fallback[root] ?? false
                }
                continue
            }
            let name = (path as NSString).lastPathComponent
            let row = try db.child(ofParent: parentID, name: name)
            bump { $0.scannedItems += 1 }
            guard let info = Walk.lstatInfo(path) else {
                let error = errno
                guard error == ENOENT || error == ENOTDIR else {
                    bump { $0.skipped += 1 }
                    continue
                }
                if let row {
                    if row.isDirectory { try db.deleteSubtree(id: row.id) }
                    else {
                        deletes.append(row.id)
                        if deletes.count >= config.batchSize {
                            try db.deleteIDs(deletes)
                            deletes.removeAll(keepingCapacity: true)
                        }
                    }
                    bump { $0.deleted += 1 }
                }
                continue
            }
            if info.isDir {
                fallback[parent] = true
                continue
            }
            if row?.isDirectory == true {
                try db.deleteSubtree(id: row!.id)
                bump { $0.deleted += 1 }
            }
            let modified = floor(info.modified)
            if row == nil || row!.isDirectory || row!.size != info.size
                || row!.modified.timeIntervalSince1970 != modified {
                try buffer.add(IndexRow(id: try row?.id ?? takeID(), parent: parentID, name: name,
                                        isDir: false, size: info.size, modified: modified))
                bump {
                    $0.rows += 1
                    $0.files += 1
                }
            }
        }
        if isCancelled() { return }
        try buffer.flush()
        try db.deleteIDs(deletes)
        let recursive = fallback.filter(\.value).map(\.key)
        let shallow = fallback.filter { !$0.value }.map(\.key).filter { path in
            !recursive.contains { IndexedVolume.contains($0, path) }
        }
        for (roots, scanKnown) in [(recursive, true), (shallow, false)] where !roots.isEmpty {
            if isCancelled() { return }
            let reconciler = Reconciler(db: db, config: config, roots: roots,
                                        skipUnchangedDirs: false, scanKnownSubdirectories: scanKnown)
            try reconciler.run(isCancelled: isCancelled)
            bump { $0.add(reconciler.snapshot) }
        }
    }
}
