import Testing
import Foundation
@testable import Ext4Kit

@Suite struct SuperblockTests {
    private func read(_ url: URL) throws -> Superblock {
        let fd = Darwin.open(url.path, Darwin.O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }
        return try Superblock.read(fd: fd, sectorSize: 512)
    }

    @Test func parsesTrixieFixture() throws {
        let sb = try read(Fixtures.trixie)
        #expect(sb.uuid == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        #expect(sb.label == "SSDTEST")
        #expect(sb.blockSize == 4096)
        #expect(sb.blockCount == 131072)
        #expect(sb.isClean)
        #expect(sb.incompat & 0x80 != 0)   // 64bit
    }

    @Test func dirtyFixtureIsNotClean() throws {
        #expect(try !read(Fixtures.dirty).isClean)
    }

    @Test func rejectsNonExt4() {
        #expect(throws: Ext4Error.notExt4) { try Superblock(bytes: [UInt8](repeating: 0, count: 1024)) }
    }
}
