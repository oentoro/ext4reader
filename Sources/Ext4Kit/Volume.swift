import Foundation
import CLwext4

public struct Entry: Hashable, Sendable {
    public enum Kind: Sendable { case file, directory, symlink, other }
    public let name: String          // decode lossy untuk tampilan
    public let path: String          // absolut di fs, mis. "/immich/library"
    public let kind: Kind, size: UInt64, mtime: Date
    public let hasValidName: Bool    // false jika nama bukan UTF-8 valid
}

@LwExt4 public final class Volume {
    private static var counter = 0
    private static let DKIOCGETBLOCKSIZE: UInt = 0x4004_6418
    private static let DKIOCGETBLOCKCOUNT: UInt = 0x4008_6419

    public let superblock: Superblock
    private let mp: String           // "/v1" (tanpa slash akhir)
    private let devName: String
    private var fd: Int32
    private var bd: UnsafeMutablePointer<ext4_blockdev>?
    private var mounted = false

    public static func openImage(_ url: URL) throws(Ext4Error) -> Volume {
        let fd = Darwin.open(url.path, Darwin.O_RDONLY)
        if fd < 0 { throw .io(errno) }
        return try open(fd: fd)
    }

    /// `fd` milik Volume (ditutup oleh `close()` atau jika open gagal).
    public static func open(fd: Int32) throws(Ext4Error) -> Volume {
        var bsize: UInt32 = 0, bcount: UInt64 = 0
        if ioctl(fd, DKIOCGETBLOCKSIZE, &bsize) != 0 || ioctl(fd, DKIOCGETBLOCKCOUNT, &bcount) != 0 {
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                let e = errno; Darwin.close(fd); throw .io(e)
            }
            bsize = 512; bcount = UInt64(st.st_size) / 512
        }
        let sb: Superblock
        do { sb = try Superblock.read(fd: fd, sectorSize: Int(bsize)) }
        catch { Darwin.close(fd); throw error }
        counter += 1
        return try Volume(fd: fd, sb: sb, n: counter, bsize: bsize, bcount: bcount)
    }

    private init(fd: Int32, sb: Superblock, n: Int, bsize: UInt32, bcount: UInt64) throws(Ext4Error) {
        self.fd = fd; superblock = sb
        devName = "v\(n)"; mp = "/v\(n)"
        guard let bd = fd_blockdev_create(fd, bsize, bcount) else {
            Darwin.close(fd); throw .io(ENOMEM)
        }
        self.bd = bd
        var rc = ext4_device_register(bd, devName)
        if rc == EOK {
            rc = ext4_mount(devName, mp + "/", true)
            if rc != EOK { ext4_device_unregister(devName) }
        }
        if rc != EOK {
            fd_blockdev_destroy(bd); Darwin.close(fd)
            self.bd = nil; self.fd = -1
            if rc == ENOTSUP {
                throw .unsupported(String(format: "incompat=0x%X ro_compat=0x%X", sb.incompat, sb.roCompat))
            }
            throw .io(rc)
        }
        mounted = true
    }

    private func cpath(_ path: String) -> String { path == "/" ? mp + "/" : mp + path }

    private static func kind(mode: UInt32) -> Entry.Kind {
        switch mode & UInt32(EXT4_INODE_MODE_TYPE_MASK) {
        case UInt32(EXT4_INODE_MODE_FILE): .file
        case UInt32(EXT4_INODE_MODE_DIRECTORY): .directory
        case UInt32(EXT4_INODE_MODE_SOFTLINK): .symlink
        default: .other
        }
    }

    /// `fsPath` = path di fs, `cPath` = path lwext4 sebagai byte mentah.
    private func makeEntry(name: String, valid: Bool, fsPath: String, cPath: [UInt8]) throws(Ext4Error) -> Entry {
        var ino: UInt32 = 0
        var inode = ext4_inode()
        let rc = cPath.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: CChar.self, capacity: $0.count) {
                ext4_raw_inode_fill($0, &ino, &inode)
            }
        }
        if rc == ENOENT { throw .notFound(fsPath) }
        if rc != EOK { throw .io(rc) }
        return try entry(from: &inode, name: name, valid: valid, fsPath: fsPath)
    }

    private func entry(from inode: inout ext4_inode, name: String, valid: Bool, fsPath: String) throws(Ext4Error) -> Entry {
        var sbp: UnsafeMutablePointer<ext4_sblock>?
        let rs = ext4_get_sblock(mp + "/", &sbp)
        guard rs == EOK, let sb = sbp else { throw .io(rs) }
        return Entry(name: name, path: fsPath,
                     kind: Self.kind(mode: ext4_inode_get_mode(sb, &inode)),
                     size: ext4_inode_get_size(sb, &inode),
                     mtime: Date(timeIntervalSince1970: TimeInterval(ext4_inode_get_modif_time(&inode))),
                     hasValidName: valid)
    }

    public func entry(_ path: String) throws(Ext4Error) -> Entry {
        let name = path == "/" ? "/" : String(path.split(separator: "/").last ?? "")
        return try makeEntry(name: name, valid: !path.contains("\u{FFFD}"),
                             fsPath: path, cPath: Array(cpath(path).utf8) + [0])
    }

    public func list(_ path: String) throws(Ext4Error) -> [Entry] {
        let dirC = cpath(path)
        var dir = ext4_dir()
        let rc = ext4_dir_open(&dir, dirC)
        if rc == ENOENT { throw .notFound(path) }
        if rc != EOK { throw .io(rc) }
        defer { ext4_dir_close(&dir) }
        let fsBase = path == "/" ? "/" : path + "/"
        var out: [Entry] = []
        while let e = ext4_dir_entry_next(&dir) {
            let bytes: [UInt8] = withUnsafeBytes(of: e.pointee.name) { Array($0.prefix(Int(e.pointee.name_length))) }
            if bytes == [0x2E] || bytes == [0x2E, 0x2E] { continue }
            let valid = String(bytes: bytes, encoding: .utf8)
            let name = valid ?? String(decoding: bytes, as: UTF8.self)
            var inode = ext4_inode()
            let r = ext4_raw_inode_fill_by_ino(mp + "/", e.pointee.inode, &inode)
            if r != EOK { throw .io(r) }
            out.append(try entry(from: &inode, name: name, valid: valid != nil, fsPath: fsBase + name))
        }
        return out.sorted {
            let c = $0.name.localizedStandardCompare($1.name)
            return c == .orderedSame ? $0.path < $1.path : c == .orderedAscending
        }
    }

    /// Potongan 1 MiB. Gagal baca/buka lwext4 -> `Ext4Error.io(rc)` (untuk deteksi disk dicabut).
    public func read(_ path: String, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        if path.contains("\u{FFFD}") { throw Ext4Error.unsupported("nama bukan UTF-8 valid") }
        var f = ext4_file()
        var rc = ext4_fopen(&f, cpath(path), "rb")
        if rc == ENOENT { throw Ext4Error.notFound(path) }
        if rc != EOK { throw Ext4Error.io(rc) }
        defer { ext4_fclose(&f) }
        let chunk = 1 << 20
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        while true {
            var n = 0
            rc = ext4_fread(&f, buf.baseAddress, chunk, &n)
            if rc != EOK { throw Ext4Error.io(rc) }
            if n == 0 { break }
            try body(UnsafeRawBufferPointer(rebasing: buf[0..<n]))
        }
    }

    public func close() {
        if mounted { ext4_umount(mp + "/"); ext4_device_unregister(devName); mounted = false }
        if let b = bd { fd_blockdev_destroy(b); bd = nil }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}
