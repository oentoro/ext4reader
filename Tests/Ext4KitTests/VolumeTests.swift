import Testing
import Foundation
@testable import Ext4Kit

@Suite struct VolumeTests {
    @Test @LwExt4 func listsAndReadsIdenticalToSource() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let p = "/immich/library/library/admin/2026/08/01/IMG_5772.heic"
        var data = Data(); try v.read(p) { data.append(contentsOf: $0) }
        #expect(data == (try Data(contentsOf: Fixtures.srcTree.appending(path: String(p.dropFirst())))))
        let e = try v.entry(p)
        #expect(e.kind == .file && e.size == UInt64(data.count))
        #expect(abs(e.mtime.timeIntervalSince(srcMtime(p))) < 1)
        let names = try v.list("/immich/library/library/admin/2026/07").map(\.name)
        #expect(names == ["01", "02"])
    }
    @Test @LwExt4 func hugeSparseFileSize() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        #expect(try v.entry("/big/huge.bin").size == 5 * (1 << 30))
    }
    @Test @LwExt4 func symlinkKind() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        #expect(try v.entry("/links/l").kind == .symlink)
    }
    @Test @LwExt4 func invalidUtf8NameListedButUnreadable() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let es = try v.list("/names")
        let bad = try #require(es.first { !$0.hasValidName })
        #expect(throws: Ext4Error.unsupported("nama bukan UTF-8 valid")) { try v.read(bad.path) { _ in } }
        #expect(es.filter(\.hasValidName).count == es.count - 1)
    }
    @Test @LwExt4 func validNameContainingReplacementCharIsReadable() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let e = try #require(try v.list("/names").first { $0.name == "x\u{FFFD}.txt" })
        #expect(e.hasValidName)
        #expect(try v.entry(e.path).hasValidName)
        var data = Data(); try v.read(e.path) { data.append(contentsOf: $0) }
        #expect(data == Data("replacement-char\n".utf8))
    }
    @Test @LwExt4 func listsTwentyThousandEntriesFast() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let t = ContinuousClock.now; let es = try v.list("/bigdir")
        #expect(es.count == 20000); #expect(ContinuousClock.now - t < .seconds(2))
    }
    @Test @LwExt4 func readOnlyLeavesImageByteIdentical() throws {
        let before = sha256(Fixtures.trixie)
        let v = try Volume.openImage(Fixtures.trixie); _ = try v.list("/bigdir"); try v.read("/names/A.jpg") { _ in }; v.close()
        #expect(sha256(Fixtures.trixie) == before)
    }
    @Test @LwExt4 func twoVolumesAtOnce() throws {
        let a = try Volume.openImage(Fixtures.trixie); defer { a.close() }
        let b = try Volume.openImage(Fixtures.dirty); defer { b.close() }
        #expect(!(try a.list("/")).isEmpty); #expect(!(try b.list("/")).isEmpty)
    }
    @Test @LwExt4 func mediaFilesReadByteIdentical() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        for p in ["/media/big-odd.bin", "/media/frag.bin"] {
            let src = Fixtures.srcTree.appending(path: String(p.dropFirst()))
            var data = Data(); try v.read(p) { data.append(contentsOf: $0) }
            #expect(data == (try Data(contentsOf: src)))
            #expect(try v.entry(p).size == UInt64(data.count))
        }
        #expect(try v.entry("/media/big-odd.bin").size == 3_000_001)
    }
    @Test @LwExt4 func useAfterCloseThrowsENXIO() throws {
        let v = try Volume.openImage(Fixtures.trixie)
        let f = try v.open("/names/A.jpg")
        v.close()
        #expect(throws: Ext4Error.io(ENXIO)) { try v.list("/") }
        #expect(throws: Ext4Error.io(ENXIO)) { try v.entry("/names") }
        #expect(throws: Ext4Error.io(ENXIO)) { try v.open("/names/A.jpg") }
        #expect(throws: Ext4Error.io(ENXIO)) { try f.read { _ in } }
        f.close()
    }
    @Test @LwExt4 func closeIsIdempotent() throws {
        let v = try Volume.openImage(Fixtures.trixie); v.close(); v.close()
    }
}
