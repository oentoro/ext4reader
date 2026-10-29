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

    @Test @LwExt4 func preexistingPartialsAreNeverTouched() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let tmp = tmpDir()
        let dir = tmp.appending(path: "admin/2026/07")
        let d1 = dir.appending(path: "01"), d2 = dir.appending(path: "02")
        try FileManager.default.createDirectory(at: d1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d2, withIntermediateDirectories: true)
        let reg = d1.appending(path: ".IMG_0001.heic.partial")
        try Data("milik-user".utf8).write(to: reg)
        let victim = tmp.appending(path: "victim.txt")
        try Data("jangan-sentuh".utf8).write(to: victim)
        let link = d2.appending(path: ".IMG_0002.heic.partial")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: victim.path)
        let plan = try makePlan(v, root: Self.lib, selection: sel("admin/2026/07"), destination: tmp)
        let r = runBackup(plan, volume: v, destination: tmp, progress: { _ in }, isCancelled: { false })
        #expect(r.failures.isEmpty && r.copied.count == 2)
        #expect(try Data(contentsOf: reg) == Data("milik-user".utf8))
        #expect(try Data(contentsOf: victim) == Data("jangan-sentuh".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == victim.path)
        for n in ["01/IMG_0001", "02/IMG_0002"] {
            #expect(sha256(dir.appending(path: n + ".heic")) == sha256(Fixtures.srcTree.appending(path: "immich/library/library/admin/2026/07/" + n + ".heic")))
        }
        #expect(partials(in: tmp).sorted() == ["admin/2026/07/01/.IMG_0001.heic.partial", "admin/2026/07/02/.IMG_0002.heic.partial"])
    }

    @Test @LwExt4 func destinationRemovedMidRunStopsWithoutRecreating() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let parent = tmpDir()
        let dest = parent.appending(path: "dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let plan = try makePlan(v, root: Self.lib, selection: sel("admin"), destination: dest)
        var moved = false
        let r = runBackup(plan, volume: v, destination: dest, progress: {
            if $0.filesDone == 1 && !moved { moved = true; try? FileManager.default.moveItem(at: dest, to: parent.appending(path: "away")) }
        }, isCancelled: { false })
        #expect(r.stopReason == .destinationMissing)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
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
        #expect(r.copied.count == 1)
        #expect(r.failures.count >= 1 && r.failures.allSatisfy { $0.message.contains("membaca") })
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

    @Test @LwExt4 func bytesDoneNeverDecreasesWhenFileFailsMidCopy() throws {
        let copy = tmpDir().appending(path: "copy.img")
        try FileManager.default.copyItem(at: Fixtures.trixie, to: copy)
        let v = try Volume.openImage(copy); defer { v.close() }
        let tmp = tmpDir()
        let plan = try makePlan(v, root: "/", selection: sel("media"), destination: tmp)
        #expect(plan.items.map(\.relativePath) == ["media/big-odd.bin", "media/frag.bin"])
        var seen: [UInt64] = []
        var cut = false, restored = false
        let r = runBackup(plan, volume: v, destination: tmp, progress: {
            seen.append($0.bytesDone)
            // potong image di tengah big-odd.bin (setelah potongan pertama)
            if $0.filesDone == 0 && $0.bytesDone > 0 && !cut { cut = true; truncate(copy.path, 0) }
        }, isCancelled: {
            // dipanggil di awal file berikutnya: kembalikan isi image (inode sama) agar frag.bin terbaca
            if cut && !restored { restored = true; shell("cat '\(Fixtures.trixie.path)' > '\(copy.path)'") }
            return false
        })
        #expect(cut && restored)
        #expect(r.failures.map(\.path) == ["media/big-odd.bin"] && r.copied == ["media/frag.bin"])
        #expect(seen.count >= 2 && zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(seen.last == plan.bytesToCopy)
        #expect(partials(in: tmp).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tmp.appending(path: "media/big-odd.bin").path))
    }

    @Test @LwExt4 func closedVolumeStopsWithoutCreatingFolders() throws {
        let v = try Volume.openImage(Fixtures.trixie)
        let tmp = tmpDir()
        let plan = try makePlan(v, root: Self.lib, selection: sel("admin"), destination: tmp)
        v.close()
        let r = runBackup(plan, volume: v, destination: tmp, progress: { _ in }, isCancelled: { false })
        #expect(r.stopReason == .diskDisconnected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty)
    }

    @Test @LwExt4 func exfatDestinationRoundTrips() throws {
        let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
        let work = tmpDir()
        let img = work.appending(path: "x.dmg")
        let mnt = work.appending(path: "mnt")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        #expect(shell("hdiutil create -size 20m -fs ExFAT -volname X '\(img.path)' >/dev/null 2>&1") == 0)
        #expect(shell("hdiutil attach -nobrowse -mountpoint '\(mnt.path)' '\(img.path)' >/dev/null 2>&1") == 0)
        defer { shell("hdiutil detach -force '\(mnt.path)' >/dev/null 2>&1") }
        let plan = try makePlan(v, root: Self.lib, selection: sel("admin"), destination: mnt)
        #expect(plan.availableBytes > 0 && plan.hasEnoughSpace)
        let r = runBackup(plan, volume: v, destination: mnt, progress: { _ in }, isCancelled: { false })
        #expect(r.failures.isEmpty && r.stopReason == nil && r.copied.count == 3)
        for rel in r.copied {
            #expect(sha256(mnt.appending(path: rel)) == sha256(Fixtures.srcTree.appending(path: "immich/library/library/" + rel)))
        }
        let again = try makePlan(v, root: Self.lib, selection: sel("admin"), destination: mnt)
        #expect(again.counts.copy == 0 && again.counts.conflict == 0)
        #expect(partials(in: mnt).isEmpty)
    }

    @Test func renameExclusiveNeverOverwrites() throws {
        let d = tmpDir()
        let a = d.appending(path: "a"), b = d.appending(path: "b")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        #expect(renameExclusive(a.path, b.path) == EEXIST)
        #expect(try Data(contentsOf: b) == Data("b".utf8))
    }

    @Test func reportTextListsSections() {
        var r = BackupReport()
        r.stopReason = .diskDisconnected
        let t = r.text()
        for s in ["Disalin:", "Dilewati:", "Konflik:", "Gagal:", "Disk terputus"] { #expect(t.contains(s)) }
    }
}
