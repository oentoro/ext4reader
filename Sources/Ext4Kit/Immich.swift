import Foundation

/// Cari direktori D (kedalaman ≤ 4, BFS, hanya direktori) yang punya subfolder "library", "upload",
/// serta "thumbs" atau "encoded-video". Hasil: "D/library". Nil jika tidak ketemu.
@LwExt4 public func suggestedImmichRoot(_ v: Volume) -> String? {
    let maxDepth = 4
    var queue: [(path: String, depth: Int)] = [("/", 0)]
    var head = 0
    while head < queue.count {
        let (dir, depth) = queue[head]
        head += 1
        // Folder yang gagal dibaca dilewati saja.
        guard let children = try? v.list(dir) else { continue }
        let dirs = children.filter { $0.kind == .directory && $0.hasValidName }
        let names = Set(dirs.map(\.name))
        if names.contains("library") && names.contains("upload")
            && (names.contains("thumbs") || names.contains("encoded-video")) {
            return (dir == "/" ? "" : dir) + "/library"
        }
        if depth < maxDepth {
            queue += dirs.map { (path: $0.path, depth: depth + 1) }
        }
    }
    return nil
}
