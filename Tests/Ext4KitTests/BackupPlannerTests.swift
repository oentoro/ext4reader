import Testing
import Foundation
@testable import Ext4Kit

@Suite struct BackupPlannerTests {
    static let lib = "/immich/library/library"
    static let f1 = "admin/2026/07/01/IMG_0001.heic"
    static let d1 = "01/IMG_0001.heic"   // tujuan f1 saat memilih "admin/2026/07/01"

    func copyFile(_ rel: String, into tmp: URL, to name: String? = nil, mtimeOffset: TimeInterval = 0, extra: Bool = false) throws {
        let dst = tmp.appending(path: name ?? rel)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.srcTree.appending(path: "immich/library/library/" + rel), to: dst)
        if extra { let h = try FileHandle(forWritingTo: dst); try h.seekToEnd(); try h.write(contentsOf: Data([1])); try h.close() }
        let m = srcMtime("/immich/library/library/" + rel).addingTimeInterval(mtimeOffset)
        try FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: dst.path)
    }

    @Test @LwExt4 func freshDestinationCopiesSelection() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let p = try makePlan(v, root: Self.lib, selection: sel("admin/2026/07"), destination: tmpDir())
        #expect(p.items.map(\.action) == [.copy(to: "07/01/IMG_0001.heic"), .copy(to: "07/02/IMG_0002.heic")])
        #expect(p.counts.copy == 2 && p.bytesToCopy == p.items.reduce(0) { $0 + $1.size })
        #expect(p.hasEnoughSpace)
    }
    @Test @LwExt4 func matchingFileIsSkipped() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let t = tmpDir(); try copyFile(Self.f1, into: t, to: Self.d1, mtimeOffset: 1)
        let p = try makePlan(v, root: Self.lib, selection: sel("admin/2026/07/01"), destination: t)
        #expect(p.items.map(\.action) == [.skip])
    }
    @Test @LwExt4 func differingFileBecomesConflictTwo() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let t = tmpDir(); try copyFile(Self.f1, into: t, to: Self.d1, extra: true)
        let p = try makePlan(v, root: Self.lib, selection: sel("admin/2026/07/01"), destination: t)
        #expect(p.items.map(\.action) == [.conflict(to: "01/IMG_0001 (2).heic")])
    }
    @Test @LwExt4 func earlierConflictCopyMatchingIsSkipped() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let t = tmpDir(); try copyFile(Self.f1, into: t, to: Self.d1, extra: true)
        try copyFile(Self.f1, into: t, to: "01/IMG_0001 (2).heic")
        let p = try makePlan(v, root: Self.lib, selection: sel("admin/2026/07/01"), destination: t)
        #expect(p.items.map(\.action) == [.skip])
    }
    @Test @LwExt4 func caseCollisionInSameRun() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let p = try makePlan(v, root: "/names", selection: sel("A.jpg", "a.jpg"), destination: tmpDir())
        #expect(Set(p.items.map(\.action)) == [.copy(to: "A.jpg"), .conflict(to: "a (2).jpg")])
    }
    @Test @LwExt4 func unicodeNormalizationCollision() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let p = try makePlan(v, root: "/names", selection: sel(""), destination: tmpDir())
        let caf = p.items.filter { $0.relativePath.lowercased().hasPrefix("caf") }
        #expect(caf.count == 2)
        let copies = caf.compactMap { if case .copy(let t) = $0.action { t } else { nil } }
        let confl = caf.compactMap { if case .conflict(let t) = $0.action { t } else { nil } }
        #expect(copies.count == 1 && confl.count == 1)
        #expect(confl.first.map { Array($0.unicodeScalars) == Array("caf\u{E9} (2).txt".unicodeScalars) } == true)
    }
    @Test @LwExt4 func invalidNamedDirectoryFailsPerItem() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let p = try makePlan(v, root: "/baddirs", selection: sel(""), destination: tmpDir())
        #expect(p.items.map(\.action) == [.fail("nama bukan UTF-8 valid")])
    }
    @Test @LwExt4 func directoryAtFilePathIsNotSkipped() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let t = tmpDir()
        try FileManager.default.createDirectory(at: t.appending(path: Self.d1), withIntermediateDirectories: true)
        let p = try makePlan(v, root: Self.lib, selection: sel("admin/2026/07/01"), destination: t)
        #expect(p.items.map(\.action) == [.conflict(to: "01/IMG_0001 (2).heic")])
    }
    @Test @LwExt4 func fileWhereFolderShouldBeFails() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let t = tmpDir()
        try Data([1]).write(to: t.appending(path: "07"))
        let p = try makePlan(v, root: Self.lib, selection: sel("admin/2026/07"), destination: t)
        #expect(p.items.count == 2 && p.items.allSatisfy { $0.action == .fail("tujuan bukan folder") })
    }
    @Test @LwExt4 func symlinkAndBadNameFail() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let p = try makePlan(v, root: "/", selection: sel("links", "names"), destination: tmpDir())
        #expect(p.items.contains { $0.relativePath == "links/l" && $0.action == .fail("dilewati: symlink") })
        #expect(p.items.contains { $0.relativePath.hasPrefix("names/bad") && $0.action == .fail("nama bukan UTF-8 valid") })
        #expect(p.counts.fail == 2)
    }
    @Test @LwExt4 func dirtyVolumeRefused() throws {
        let v = try Volume.openImage(Fixtures.dirty); defer { v.close() }
        #expect(throws: Ext4Error.notClean) { try makePlan(v, root: "/", selection: sel(""), destination: tmpDir()) }
        #expect(throws: Never.self) { try makePlan(v, root: "/", selection: sel(""), destination: tmpDir(), allowUnclean: true) }
    }
    @Test @LwExt4 func missingDestinationRefusedAndNotCreated() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let d = URL(filePath: "/tmp/ext4reader-tidak-ada-\(UUID())")
        #expect(throws: Ext4Error.destinationMissing) { try makePlan(v, root: "/", selection: sel("names"), destination: d) }
        #expect(!FileManager.default.fileExists(atPath: d.path))
    }
    @Test @LwExt4 func missingSelectionReported() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let p = try makePlan(v, root: Self.lib, selection: sel("admin/2025"), destination: tmpDir())
        #expect(p.missingSelections == ["admin/2025"] && p.items.isEmpty)
    }
    @Test @LwExt4 func excludedBranchNotVisited() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        var s = sel("admin"); s.set("admin/2026/08", false)
        let p = try makePlan(v, root: Self.lib, selection: s, destination: tmpDir())
        #expect(p.items.count == 2 && !p.items.contains { $0.relativePath.contains("IMG_5772") })
    }
}
