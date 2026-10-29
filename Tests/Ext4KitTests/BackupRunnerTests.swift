import Testing
import Foundation
@testable import Ext4Kit

@Suite struct BackupRunnerTests {
    static let lib = "/immich/library/library"

    func partials(in dir: URL) -> [String] {
        let e = FileManager.default.enumerator(atPath: dir.path)
        return (e?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".partial") }
    }

    @Test @LwExt4 func endToEndMatchesSourceAndRerunSkipsAll() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let tmp = tmpDir()
        let plan = try makePlan(v, root: Self.lib, selection: sel("admin"), destination: tmp)
        let r = runBackup(plan, volume: v, destination: tmp, progress: { _ in }, isCancelled: { false })
        #expect(r.failures.isEmpty && r.stopReason == nil)
        #expect(r.copied.count == 3)
        #expect(shell("diff -r '\(Fixtures.srcTree.path)/immich/library/library/admin' '\(tmp.path)/admin' --exclude=.immich") == 0)
        let a = try FileManager.default.attributesOfItem(atPath: tmp.appending(path: "admin/2026/08/01/IMG_5772.heic").path)
        let want = try v.entry(Self.lib + "/admin/2026/08/01/IMG_5772.heic").mtime
        #expect(abs((a[.modificationDate] as! Date).timeIntervalSince(want)) <= 1)
        let again = try makePlan(v, root: Self.lib, selection: sel("admin"), destination: tmp)
        #expect(again.counts.copy == 0 && again.counts.conflict == 0)
        #expect(partials(in: tmp).isEmpty)
    }

    @Test @LwExt4 func neverOverwritesExistingFile() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let tmp = tmpDir()
        let rel = "admin/2026/07/01/IMG_0001.heic"
        let dst = tmp.appending(path: rel)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("lain".utf8).write(to: dst)
        let plan = try makePlan(v, root: Self.lib, selection: sel("admin/2026/07/01"), destination: tmp)
        #expect(plan.counts.conflict == 1)
        let r = runBackup(plan, volume: v, destination: tmp, progress: { _ in }, isCancelled: { false })
        #expect(r.conflicts.count == 1 && r.failures.isEmpty)
        #expect(try Data(contentsOf: dst) == Data("lain".utf8))
        let two = tmp.appending(path: "admin/2026/07/01/IMG_0001 (2).heic")
        #expect(sha256(two) == sha256(Fixtures.srcTree.appending(path: "immich/library/library/" + rel)))
    }

    @Test @LwExt4 func cancelLeavesNoPartial() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let tmp = tmpDir()
        let plan = try makePlan(v, root: "/big", selection: sel("huge.bin"), destination: tmp)
        var started = false
        let r = runBackup(plan, volume: v, destination: tmp,
                          progress: { if $0.bytesDone > 0 { started = true } }, isCancelled: { started })
        #expect(r.stopReason == .cancelled)
        #expect(partials(in: tmp).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tmp.appending(path: "huge.bin").path))
    }

    @Test @LwExt4 func diskDisconnectStopsCleanly() throws {
        let copy = tmpDir().appending(path: "copy.img")
        try FileManager.default.copyItem(at: Fixtures.trixie, to: copy)
        let v = try Volume.openImage(copy); defer { v.close() }
        let tmp = tmpDir()
        let plan = try makePlan(v, root: Self.lib, selection: sel("admin"), destination: tmp)
        var cut = false
        let r = runBackup(plan, volume: v, destination: tmp, progress: {
            if $0.filesDone == 1 && !cut { cut = true; truncate(copy.path, 0) }
        }, isCancelled: { false })
        #expect(r.stopReason == .diskDisconnected)
        #expect(partials(in: tmp).isEmpty)
    }

    @Test @LwExt4 func destinationFullStopsCleanly() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let work = tmpDir()
        let img = work.appending(path: "t.dmg")
        let mnt = work.appending(path: "mnt")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        #expect(shell("hdiutil create -size 2m -fs HFS+ -volname T '\(img.path)' >/dev/null 2>&1") == 0)
        #expect(shell("hdiutil attach -nobrowse -mountpoint '\(mnt.path)' '\(img.path)' >/dev/null 2>&1") == 0)
        defer { shell("hdiutil detach -force '\(mnt.path)' >/dev/null 2>&1") }
        shell("dd if=/dev/zero of='\(mnt.path)/filler' bs=4096 >/dev/null 2>&1")   // berhenti saat penuh
        let plan = try makePlan(v, root: Self.lib, selection: sel("admin"), destination: mnt)
        let r = runBackup(plan, volume: v, destination: mnt, progress: { _ in }, isCancelled: { false })
        #expect(r.stopReason == .destinationFull)
        #expect(partials(in: mnt).isEmpty)
    }

    @Test func reportTextListsSections() {
        var r = BackupReport()
        r.stopReason = .diskDisconnected
        let t = r.text()
        for s in ["Disalin:", "Dilewati:", "Konflik:", "Gagal:", "Disk terputus"] { #expect(t.contains(s)) }
    }
}
