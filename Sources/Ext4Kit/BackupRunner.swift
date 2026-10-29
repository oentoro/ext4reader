import Foundation

public struct BackupProgress: Sendable {
    public let filesDone, filesTotal: Int
    public let bytesDone, bytesTotal: UInt64
    public let currentPath: String
}

public struct BackupReport: Sendable {
    public var copied: [String] = []
    public var skipped = 0
    public var conflicts: [(source: String, dest: String)] = []
    public var failures: [(path: String, message: String)] = []
    public var stopReason: Ext4Error?     // .cancelled, .diskDisconnected, .destinationFull, .destinationMissing
    public init() {}

    /// Laporan bahasa Indonesia, bisa disimpan ke .txt.
    public func text() -> String {
        var l: [String] = []
        if let s = stopReason {
            let m = switch s {
            case .cancelled: "Dibatalkan"
            case .diskDisconnected: "Disk terputus"
            case .destinationFull: "Disk tujuan penuh"
            case .destinationMissing: "Folder tujuan tidak ditemukan"
            default: "Berhenti: \(s)"
            }
            l.append(m)
            l.append("")
        }
        l.append("Disalin: \(copied.count)")
        l += copied.map { "  \($0)" }
        l.append("Dilewati: \(skipped)")
        l.append("Konflik: \(conflicts.count)")
        l += conflicts.map { "  \($0.source) -> \($0.dest)" }
        l.append("Gagal: \(failures.count)")
        l += failures.map { "  \($0.path): \($0.message)" }
        return l.joined(separator: "\n") + "\n"
    }
}

private struct WriteFailure: Error { let errno: Int32 }

@LwExt4 public func runBackup(_ plan: BackupPlan, volume: Volume, destination: URL,
                              progress: (BackupProgress) -> Void, isCancelled: () -> Bool) -> BackupReport {
    var report = BackupReport()
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
        report.stopReason = .destinationMissing
        return report
    }
    let fm = FileManager.default
    let todo = plan.items.filter { if case .copy = $0.action { true } else if case .conflict = $0.action { true } else { false } }
    let total = UInt64(todo.reduce(0) { $0 + Int($1.size) })
    var filesDone = 0, bytesDone: UInt64 = 0
    var badReads = 0   // file berturut-turut gagal baca dengan errno "disk hilang"
    let gone: Set<Int32> = [EIO, ENXIO, ENODEV, EBADF]

    for item in plan.items {
        let rel: String, isConflict: Bool
        switch item.action {
        case .skip: report.skipped += 1; continue
        case .fail(let m): report.failures.append((item.relativePath, m)); continue
        case .copy(let to): rel = to; isConflict = false
        case .conflict(let to): rel = to; isConflict = true
        }
        var rootIsDir: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &rootIsDir), rootIsDir.boolValue else {
            report.stopReason = .destinationMissing; return report   // jangan pernah membuat ulang folder tujuan
        }
        if isCancelled() { report.stopReason = .cancelled; return report }
        // bytesDone hanya naik: file yang gagal tetap dihitung penuh agar progress mencapai 100%.
        let startBytes = bytesDone
        defer { bytesDone = max(bytesDone, startBytes + item.size) }

        let final = destination.appending(path: rel)
        var partial = final   // diganti dengan nama partial unik yang kita buat sendiri
        func emit() {
            progress(BackupProgress(filesDone: filesDone, filesTotal: todo.count,
                                    bytesDone: bytesDone, bytesTotal: total, currentPath: item.relativePath))
        }
        func abort(_ message: String) { unlink(partial.path); report.failures.append((item.relativePath, message)) }

        // Buka sumber dulu: sumber yang mati tidak boleh meninggalkan pohon folder kosong di tujuan.
        let src: Volume.OpenFile
        do { src = try volume.open(item.sourcePath) }
        catch {
            if case Ext4Error.io(let rc) = error, gone.contains(rc) {
                badReads += 1
                report.failures.append((item.relativePath, "gagal membaca dari disk"))
                if badReads >= 2 { report.stopReason = .diskDisconnected; return report }
                continue
            }
            badReads = 0
            report.failures.append((item.relativePath, "\(error)")); continue
        }
        defer { src.close() }

        do { try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch {
            let ns = error as NSError
            if ns.code == NSFileWriteOutOfSpaceError || (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOSPC) {
                report.stopReason = .destinationFull; return report
            }
            report.failures.append((item.relativePath, "gagal membuat folder: \(error.localizedDescription)")); continue
        }
        // Nama acak + O_EXCL|O_NOFOLLOW: tidak pernah menyentuh/menghapus file yang bukan buatan kita.
        var fd: Int32 = -1, openErr: Int32 = EEXIST
        for _ in 0..<5 where fd < 0 && openErr == EEXIST {
            let hex = String(format: "%08x", UInt32.random(in: .min ... .max))
            partial = final.deletingLastPathComponent().appending(path: "." + final.lastPathComponent + ".\(hex).partial")
            fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            if fd < 0 { openErr = errno }
        }
        if fd < 0 {
            if openErr == ENOSPC { report.stopReason = .destinationFull; return report }
            report.failures.append((item.relativePath, String(cString: strerror(openErr)))); continue
        }
        var cancelled = false
        do {
            try src.read { chunk in
                if isCancelled() { cancelled = true; throw Ext4Error.cancelled }
                var off = 0
                while off < chunk.count {
                    let n = write(fd, chunk.baseAddress! + off, chunk.count - off)
                    if n < 0 { if errno == EINTR { continue }; throw WriteFailure(errno: errno) }
                    off += n
                }
                bytesDone += UInt64(chunk.count)
                emit()
            }
        } catch {
            close(fd)
            unlink(partial.path)
            if cancelled { report.stopReason = .cancelled; return report }
            if let w = error as? WriteFailure {
                if w.errno == ENOSPC { report.stopReason = .destinationFull; return report }
                report.failures.append((item.relativePath, String(cString: strerror(w.errno)))); badReads = 0; continue
            }
            if case Ext4Error.io(let rc) = error, gone.contains(rc) {
                badReads += 1
                report.failures.append((item.relativePath, "gagal membaca dari disk"))
                if badReads >= 2 { report.stopReason = .diskDisconnected; return report }
                continue
            }
            badReads = 0
            report.failures.append((item.relativePath, "\(error)")); continue
        }
        badReads = 0
        var syncErr: Int32 = 0
        if fcntl(fd, F_FULLFSYNC) != 0 {
            let e = errno
            if (e == ENOTSUP || e == EINVAL) && fsync(fd) != 0 { syncErr = errno }
            else if e != ENOTSUP && e != EINVAL { syncErr = e }
        }
        if close(fd) != 0 && syncErr == 0 { syncErr = errno }
        if syncErr != 0 {
            let e = syncErr
            unlink(partial.path)
            if e == ENOSPC { report.stopReason = .destinationFull; return report }
            report.failures.append((item.relativePath, String(cString: strerror(e)))); continue
        }
        do { try fm.setAttributes([.modificationDate: item.mtime], ofItemAtPath: partial.path) }
        catch { abort("gagal mengatur tanggal: \(error.localizedDescription)"); continue }
        if let e = renameExclusive(partial.path, final.path) {
            abort(e == EEXIST ? "tujuan sudah ada, tidak ditimpa" : String(cString: strerror(e)))
            continue
        }
        filesDone += 1
        if isConflict { report.conflicts.append((item.sourcePath, rel)) } else { report.copied.append(rel) }
        emit()
    }
    return report
}

/// `rename` yang tidak pernah menimpa. nil = sukses, selain itu errno (EEXIST jika tujuan sudah ada).
func renameExclusive(_ from: String, _ to: String) -> Int32? {
    if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return nil }
    let e = errno
    guard e == ENOTSUP || e == EINVAL else { return e }
    // Fallback untuk exFAT/FAT yang tidak mendukung RENAME_EXCL.
    // ponytail: ada jendela TOCTOU kecil antara lstat dan rename; hanya proses lain yang membuat
    // file bernama sama tepat di celah itu yang bisa tertimpa. Diterima untuk tujuan non-APFS/HFS.
    var st = stat()
    if lstat(to, &st) == 0 { return EEXIST }
    if errno != ENOENT { return errno }
    return rename(from, to) == 0 ? nil : errno
}
