import SwiftUI
import Ext4Kit

@MainActor @Observable final class BrowserModel {
    struct Source: Identifiable {
        let id: String            // path image atau BSD name
        let title: String
        var status: Status
        var volume: Volume?
        var uuid: UUID?
    }
    enum Status { case readOnly, notClean, unsupported(String), needsOpen }

    var sources: [Source] = []
    var selectedSourceID: String? { didSet { if oldValue != selectedSourceID { loadSettings() } } }
    /// Milik source terpilih; disimpan otomatis setiap kali berubah.
    var settings = DiskSettings() {
        didSet {
            guard !loadingSettings, let uuid = selected?.uuid else { return }
            try? settings.save(uuid: uuid)
            if settings.selection != oldValue.selection || settings.backupRoot != oldValue.backupRoot { recomputeTotals() }
        }
    }
    var totals: (files: Int, bytes: UInt64)?      // nil = "menghitung…"
    var immichSuggestion: String?                 // alert saran akar
    var pendingRoot: String?                      // alert peringatan ganti akar (spec §6a)
    var errorMessage: String?

    private var loadingSettings = false
    private var totalsTask: Task<Void, Never>?

    var selected: Source? { sources.first { $0.id == selectedSourceID } }
    var root: String { settings.backupRoot ?? "/" }

    // MARK: - Membuka

    func openImage(_ url: URL) async {
        await register(id: url.path, title: url.lastPathComponent) { () throws(Ext4Error) -> Volume in try Volume.openImage(url) }
    }

    func addOpened(fd: Int32, id: String, title: String) async {
        await register(id: id, title: title) { () throws(Ext4Error) -> Volume in try Volume.open(fd: fd) }
    }

    private func register(id: String, title: String,
                          _ make: @escaping @LwExt4 @Sendable () throws(Ext4Error) -> Volume) async {
        if sources.contains(where: { $0.id == id }) { selectedSourceID = id; return }
        let r = await Self.open(make)
        switch r {
        case .success(let (vol, uuid, clean)):
            sources.append(Source(id: id, title: title, status: clean ? .readOnly : .notClean, volume: vol, uuid: uuid))
            selectedSourceID = id
            if settings.backupRoot == nil, let s = await Self.suggest(vol) { immichSuggestion = s }
        case .failure(let e):
            sources.append(Source(id: id, title: title, status: .unsupported(e.localizedDescription)))
            selectedSourceID = id
            errorMessage = "Tidak bisa membuka \(title): \(e)"
        }
    }

    @LwExt4 private static func open(_ make: @LwExt4 @Sendable () throws(Ext4Error) -> Volume)
        -> Result<(Volume, UUID, Bool), Ext4Error> {
        do { let v = try make(); return .success((v, v.superblock.uuid, v.superblock.isClean)) }
        catch { return .failure(error) }
    }

    @LwExt4 private static func suggest(_ v: Volume) -> String? { suggestedImmichRoot(v) }

    private func loadSettings() {
        loadingSettings = true
        defer { loadingSettings = false }
        settings = selected?.uuid.map { DiskSettings.load(uuid: $0) } ?? DiskSettings()
        recomputeTotals()
    }

    func removeSource(_ id: String) async {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        let s = sources.remove(at: i)
        if selectedSourceID == id { selectedSourceID = sources.first?.id }
        if let v = s.volume { await Self.close(v) }
    }

    func closeAll() async {
        let vols = sources.compactMap(\.volume)
        sources = []; selectedSourceID = nil
        for v in vols { await Self.close(v) }
    }

    @LwExt4 private static func close(_ v: Volume) { v.close() }

    // MARK: - Pohon

    func children(of path: String) async -> [Entry] {
        guard let v = selected?.volume else { return [] }
        return await Self.list(v, path)
    }

    @LwExt4 private static func list(_ v: Volume, _ path: String) -> [Entry] { (try? v.list(path)) ?? [] }

    /// Path absolut -> relatif ke akar; nil jika di luar akar.
    func relative(_ path: String) -> String? {
        if root == "/" { return String(path.drop { $0 == "/" }) }
        if path == root { return "" }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    func checkState(_ path: String) -> Selection.State? {
        relative(path).map { settings.selection.state(of: $0) }
    }

    func toggle(_ path: String) {
        guard let rel = relative(path) else { return }
        settings.selection.set(rel, settings.selection.state(of: rel) != .on)
    }

    func setBackupRoot(_ path: String) {
        let new: String? = path == "/" ? nil : path
        guard new != settings.backupRoot else { return }
        if settings.destination != nil { pendingRoot = path } else { applyRoot(path) }
    }

    func applyRoot(_ path: String) {
        settings.backupRoot = path == "/" ? nil : path
        settings.selection = Selection()     // path relatif lama tak berlaku lagi di akar baru
        pendingRoot = nil
    }

    func startBackup() {}   // Task 9

    // MARK: - Total terpilih

    private func recomputeTotals() {
        totalsTask?.cancel()
        totals = nil
        guard let v = selected?.volume else { return }
        let (root, sel) = (self.root, settings.selection)
        totalsTask = Task {
            let t = try? await Self.count(v, root, sel)
            if !Task.isCancelled, let t { totals = t }
        }
    }

    @LwExt4 private static func count(_ v: Volume, _ root: String, _ sel: Selection) throws -> (files: Int, bytes: UInt64) {
        var files = 0, bytes: UInt64 = 0
        _ = try enumerateSelected(v, root: root, selection: sel) { e, _ in
            try Task.checkCancellation()
            files += 1; bytes += e.size
        }
        return (files, bytes)
    }
}
