import Foundation

public struct BackupItem: Sendable, Equatable {
    public enum Action: Sendable, Hashable { case copy(to: String), skip, conflict(to: String), fail(String) }
    public let sourcePath: String      // absolut di ext4
    public let relativePath: String    // relatif ke akar
    public let size: UInt64, mtime: Date
    public let action: Action          // `to` relatif ke folder tujuan
}

public struct BackupPlan: Sendable {
    public let items: [BackupItem]
    public let missingSelections: [String]  // path tersimpan yang tidak ada lagi di disk
    public let availableBytes: Int64

    /// Jumlah size untuk `.copy` dan `.conflict`.
    public var bytesToCopy: UInt64 {
        items.reduce(0) {
            switch $1.action {
            case .copy, .conflict: $0 + $1.size
            default: $0
            }
        }
    }
    public var hasEnoughSpace: Bool { bytesToCopy <= UInt64(max(availableBytes, 0)) }

    public var counts: (copy: Int, skip: Int, conflict: Int, fail: Int) {
        var c = (copy: 0, skip: 0, conflict: 0, fail: 0)
        for i in items {
            switch i.action {
            case .copy: c.copy += 1
            case .skip: c.skip += 1
            case .conflict: c.conflict += 1
            case .fail: c.fail += 1
            }
        }
        return c
    }
}

/// Menelusuri hanya cabang yang `isSelected` atau `.mixed`; `visit` dipanggil untuk
/// setiap non-direktori terpilih. Mengembalikan path tersimpan (included) yang hilang dari disk.
@LwExt4 public func enumerateSelected(_ v: Volume, root: String, selection: Selection,
                                      visit: (Entry, _ relativePath: String) throws -> Void) throws -> [String] {
    func walk(_ dir: String, _ rel: String) throws {
        for e in try v.list(dir) {
            let childRel = rel.isEmpty ? e.name : rel + "/" + e.name
            if e.kind == .directory && !e.hasValidName {
                // path lossy: tidak bisa ditelusuri; dilaporkan sebagai item gagal
                if selection.isSelected(childRel) || selection.state(of: childRel) == .mixed { try visit(e, childRel) }
            } else if e.kind == .directory {
                if selection.isSelected(childRel) || selection.state(of: childRel) == .mixed {
                    try walk(e.path, childRel)
                }
            } else if selection.isSelected(childRel) {
                try visit(e, childRel)
            }
        }
    }
    try walk(root, "")
    var missing: [String] = []
    for p in selection.included.sorted() where !p.isEmpty {
        do { _ = try v.entry(root == "/" ? "/" + p : root + "/" + p) }
        catch { missing.append(p) }   // notFound / unsupported / io(ENOTDIR): tidak ada lagi
    }
    return missing
}

@LwExt4 public func makePlan(_ v: Volume, root: String, selection: Selection,
                             destination: URL) throws(Ext4Error) -> BackupPlan {
    guard v.superblock.isClean else { throw .notClean }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue
    else { throw .destinationMissing }
    let available = (try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
        .volumeAvailableCapacityForImportantUsage ?? 0

    var items: [BackupItem] = []
    var claimed = Set<String>()
    // ponytail: lipat huruf selalu, juga di tujuan case-sensitive; hasilnya konsisten di kedua jenis volume
    func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    func matches(_ rel: String, _ e: Entry) -> Bool? {   // nil = tidak ada di disk
        guard let a = try? FileManager.default.attributesOfItem(atPath: destination.appending(path: rel).path)
        else { return nil }
        guard a[.type] as? FileAttributeType == .typeRegular else { return false }   // ada tapi beda jenis
        let size = (a[.size] as? NSNumber)?.uint64Value
        let m = a[.modificationDate] as? Date
        return size == e.size && m.map { abs($0.timeIntervalSince(e.mtime)) <= 2 } == true
    }

    func decide(_ e: Entry, _ rel: String) -> BackupItem.Action {
        switch e.kind {
        case .symlink: return .fail("dilewati: symlink")
        case .other: return .fail("dilewati: bukan file biasa")
        default: break
        }
        if !e.hasValidName { return .fail("nama bukan UTF-8 valid") }
        var anc = destination
        for c in rel.split(separator: "/").dropLast() {
            anc = anc.appending(path: String(c))
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: anc.path, isDirectory: &d) {
                if !d.boolValue { return .fail("tujuan bukan folder") }
            } else { break }
        }
        let dot = e.name.lastIndex(of: ".").flatMap { $0 > e.name.startIndex ? $0 : nil }
        let stem = dot.map { String(e.name[..<$0]) } ?? e.name
        let ext = dot.map { String(e.name[$0...]) } ?? ""
        let dirPrefix = String(rel.dropLast(e.name.count))
        var n = 1
        while true {
            let cand = dirPrefix + (n == 1 ? e.name : "\(stem) (\(n))\(ext)")
            n += 1
            if claimed.contains(key(cand)) { continue }
            switch matches(cand, e) {
            case true?:
                claimed.insert(key(cand)); return .skip
            case false?: continue
            case nil:
                claimed.insert(key(cand))
                return n == 2 ? .copy(to: cand) : .conflict(to: cand)
            }
        }
    }

    do {
        var found: [(Entry, String)] = []
        let missing = try enumerateSelected(v, root: root, selection: selection) { e, rel in found.append((e, rel)) }
        // Nama diklaim berdasarkan urutan biner path (deterministik, "A.jpg" menang atas "a.jpg"),
        // sedangkan `items` tetap dalam urutan enumerasi.
        var actions = [Int: BackupItem.Action]()
        for i in found.indices.sorted(by: { found[$0].1.utf8.lexicographicallyPrecedes(found[$1].1.utf8) }) {
            actions[i] = decide(found[i].0, found[i].1)
        }
        items = found.indices.map { i in
            let (e, rel) = found[i]
            return BackupItem(sourcePath: e.path, relativePath: rel, size: e.size, mtime: e.mtime, action: actions[i]!)
        }
        return BackupPlan(items: items, missingSelections: missing, availableBytes: available)
    } catch let e as Ext4Error { throw e }
    catch { throw .io(EIO) }
}
