import Foundation

/// Pilihan folder/file untuk dipulihkan. Path relatif ke akar backup, tanpa "/" di depan;
/// "" berarti akar itu sendiri. `included`/`excluded` hanya mencatat titik yang berbeda
/// dari status induknya, sehingga folder baru di bawah folder terpilih ikut terpilih.
public struct Selection: Codable, Equatable, Sendable {
    public enum State: Sendable { case on, off, mixed }

    public private(set) var included: Set<String> = []
    public private(set) var excluded: Set<String> = []

    public init() {}

    /// Leluhur terdekat (atau diri sendiri) yang tercatat menentukan; default off.
    public func isSelected(_ path: String) -> Bool {
        for p in Self.lineage(path) {
            if included.contains(p) { return true }
            if excluded.contains(p) { return false }
        }
        return false
    }

    /// `mixed` jika ada turunan tercatat yang berlawanan dengan `isSelected(path)`.
    public func state(of path: String) -> State {
        let on = isSelected(path)
        let opposite = on ? excluded : included
        if opposite.contains(where: { Self.isStrictDescendant($0, of: path) }) { return .mixed }
        return on ? .on : .off
    }

    /// Hapus semua catatan path dan turunannya, lalu catat path hanya jika berbeda dari induknya.
    public mutating func set(_ path: String, _ on: Bool) {
        included = included.filter { !Self.isSelfOrDescendant($0, of: path) }
        excluded = excluded.filter { !Self.isSelfOrDescendant($0, of: path) }
        let parentOn = path.isEmpty ? false : isSelected(Self.parent(of: path))
        guard on != parentOn else { return }
        if on { included.insert(path) } else { excluded.insert(path) }
    }

    public var isEmpty: Bool { included.isEmpty }

    // MARK: - Path helpers (per komponen, bukan prefix string)

    /// `path`, induknya, ..., hingga "" (akar).
    private static func lineage(_ path: String) -> [String] {
        var out = [path]
        var p = path
        while !p.isEmpty {
            p = parent(of: p)
            out.append(p)
        }
        return out
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func isStrictDescendant(_ p: String, of ancestor: String) -> Bool {
        if ancestor.isEmpty { return !p.isEmpty }
        return p.hasPrefix(ancestor + "/")
    }

    private static func isSelfOrDescendant(_ p: String, of ancestor: String) -> Bool {
        p == ancestor || isStrictDescendant(p, of: ancestor)
    }
}
