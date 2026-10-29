import Foundation

public enum Ext4Error: Error, Equatable {
    case notExt4, io(Int32), unsupported(String), notFound(String), notClean
    case destinationMissing, cancelled, diskDisconnected, destinationFull
}

public struct Superblock: Sendable, Equatable {
    public let uuid: UUID
    public let label: String
    public let blockSize: Int
    public let blockCount: UInt64
    public let compat: UInt32, incompat: UInt32, roCompat: UInt32
    private let state: UInt16

    /// `bytes`: 1024 byte superblock (mulai offset 1024 disk).
    public init(bytes: some Collection<UInt8>) throws(Ext4Error) {
        let b = Array(bytes)
        guard b.count >= 1024 else { throw .notExt4 }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
        guard u16(0x38) == 0xEF53 else { throw .notExt4 }
        let logSize = u32(0x18)
        guard logSize <= 6 else { throw .unsupported("block size") }
        blockSize = 1024 << Int(logSize)
        compat = u32(0x5C); incompat = u32(0x60); roCompat = u32(0x64)
        state = u16(0x3A)
        var count = UInt64(u32(0x04))
        if incompat & 0x80 != 0 { count |= UInt64(u32(0x150)) << 32 }
        blockCount = count
        uuid = UUID(uuid: (b[0x68], b[0x69], b[0x6A], b[0x6B], b[0x6C], b[0x6D], b[0x6E], b[0x6F],
                           b[0x70], b[0x71], b[0x72], b[0x73], b[0x74], b[0x75], b[0x76], b[0x77]))
        label = String(decoding: b[0x78..<0x88].prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Baca 4096 byte dari offset 0 (aman untuk alignment rdisk).
    public static func read(fd: Int32, sectorSize: Int) throws(Ext4Error) -> Superblock {
        let len = max(4096, (4096 + sectorSize - 1) / sectorSize * sectorSize)
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: len, alignment: 4096)
        defer { buf.deallocate() }
        let n = pread(fd, buf.baseAddress, len, 0)
        if n < 0 { throw .io(errno) }
        guard n >= 2048 else { throw .notExt4 }
        return try Superblock(bytes: UnsafeRawBufferPointer(rebasing: buf[1024..<2048]))
    }

    public var isClean: Bool { (state & 1) != 0 && (incompat & 0x4) == 0 }
}
