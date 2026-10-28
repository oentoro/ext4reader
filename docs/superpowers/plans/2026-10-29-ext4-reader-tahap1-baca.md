# ext4 Reader — Tahap 1 (Baca & Backup) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App macOS native yang membuka disk/image ext4 secara read-only, menampilkan pohon folder bercentang, lalu membackup pilihan secara bertahap ke folder di Mac.

**Architecture:** Paket SwiftPM berisi `CLwext4` (lwext4 yang di-vendor, plus shim C untuk block device berbasis file descriptor) dan `Ext4Kit` (wrapper Swift, model pilihan, planner, dan runner backup). Semua logika diuji dengan `swift test` terhadap image fixture yang dibuat `mkfs.ext4`. App SwiftUI tipis (dibuat lewat XcodeGen) memakai `Ext4Kit`, DiskArbitration untuk deteksi disk, dan `authopen` untuk membuka `/dev/rdiskN`.

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing, SwiftPM, XcodeGen, lwext4 (C), e2fsprogs 1.47 dari Homebrew (khusus fixture), DiskArbitration.

**Spec:** `docs/superpowers/specs/2026-10-29-ext4-reader-mac-design.md`

**Di luar plan ini:** tahap 2 (menulis, spec §7) punya plan sendiri setelah tahap 1 dipakai.

## Global Constraints

- macOS 14+, universal (arm64 + x86_64), tanpa sandbox, build lokal tanpa App Store/notarization.
- Mode baca: device dan image dibuka dengan `O_RDONLY`. Callback tulis block device selalu mengembalikan `EROFS`. lwext4 di-mount dengan `read_only = true`.
- Tidak boleh ada file di tujuan yang ditimpa atau dihapus. Rename final memakai `renamex_np(..., RENAME_EXCL)`.
- File sementara bernama `.<nama>.partial` di folder tujuan file tersebut, dan dihapus saat batal atau error.
- Kecocokan "sudah dibackup" = ukuran sama **dan** `|mtime_tujuan − mtime_sumber| ≤ 2 detik`.
- Nama konflik: `<stem> (n).<ext>` dengan n mulai dari 2. File tanpa ekstensi: `<nama> (n)`.
- Semua panggilan lwext4 lewat global actor `@LwExt4`, karena lwext4 tidak thread-safe dan memakai state global.
- Teks UI dalam bahasa Indonesia.
- Commit message ditutup dengan `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **SSD tercabut saat backup:** backup berhenti dengan pesan "Disk terputus", tidak crash, dan tidak menyisakan `.partial` → test di Task 6.
2. **Disk tujuan penuh di tengah jalan** (lolos cek awal, lalu terisi proses lain): backup berhenti dengan pesan "Disk tujuan penuh", tanpa `.partial` → test di Task 6.
3. **Tujuan tersimpan sedang tidak terpasang** (misalnya `/Volumes/Backup` belum dicolok): pratinjau menolak dengan "Folder tujuan tidak ditemukan" dan tidak membuat `/Volumes/Backup` di disk internal → test di Task 5.
4. **Folder berisi puluhan ribu file:** daftar isi folder 20.000 entri selesai < 2 detik dan UI tetap responsif → test di Task 3.
5. **Nama yang sama setelah normalisasi Unicode** (`café` NFC vs NFD dalam satu folder): keduanya terbackup, yang kedua sebagai konflik → test di Task 5.

---

## Struktur File

```
Package.swift
Sources/CLwext4/src/*.c                  # lwext4 src/ (vendored, apa adanya)
Sources/CLwext4/fd_blockdev.c            # shim: ext4_blockdev di atas fd
Sources/CLwext4/include/*.h              # lwext4 include/ + include/misc/ (vendored)
Sources/CLwext4/include/fd_blockdev.h
Sources/CLwext4/include/CLwext4.h        # umbrella: ext4.h, ext4_inode.h, ext4_fs.h, fd_blockdev.h
Sources/CLwext4/LICENSE, VERSION         # lisensi lwext4 + commit yang dipin
Sources/Ext4Kit/LwExt4Actor.swift
Sources/Ext4Kit/Superblock.swift
Sources/Ext4Kit/Volume.swift
Sources/Ext4Kit/Selection.swift
Sources/Ext4Kit/BackupPlanner.swift
Sources/Ext4Kit/BackupRunner.swift
Sources/Ext4Kit/DiskSettings.swift
Sources/Ext4Kit/Immich.swift
Tests/Ext4KitTests/Fixtures.swift        # path fixture + helper tmp dir
Tests/Ext4KitTests/*Tests.swift
Tests/Fixtures/make-fixtures.sh          # output ke Tests/Fixtures/build/ (gitignored)
project.yml                              # XcodeGen: target app
App/*.swift                              # SwiftUI app
```

---

### Task 1: Vendor lwext4 + fixture trixie + spike mount

Risiko terbesar spec (§10.1) diuji di sini: apakah lwext4 bisa mount format default trixie.

**Files:**
- Create: `Package.swift`, `Sources/CLwext4/**`, `Sources/Ext4Kit/LwExt4Actor.swift`, `Tests/Fixtures/make-fixtures.sh`, `Tests/Ext4KitTests/Fixtures.swift`, `Tests/Ext4KitTests/SpikeTests.swift`
- Modify: `.gitignore` (tambah `.build/`, `Tests/Fixtures/build/`, `*.xcodeproj`)

**Interfaces:**
- Produces (C, `fd_blockdev.h`):
  `struct ext4_blockdev *fd_blockdev_create(int fd, uint32_t ph_bsize, uint64_t ph_bcnt);`
  `void fd_blockdev_destroy(struct ext4_blockdev *bd);` (tidak menutup fd)
  Callback read = `pread` dengan offset `blk_id * ph_bsize`, dan short read → `EIO`. Callback write → `EROFS`.
- Produces (Swift): `@globalActor public actor LwExt4 { public static let shared = LwExt4() }`
- Produces (test): `enum Fixtures { static var trixie: URL; static var dirty: URL; static var srcTree: URL }`. Kalau file belum ada, gagal dengan pesan `"Jalankan Tests/Fixtures/make-fixtures.sh"`.
  Helper test di file yang sama (dipakai Task 2–7): `func sel(_ paths: String...) -> Selection` (set semua ke on), `func tmpDir() -> URL` (folder baru, dihapus otomatis), `func sha256(_ url: URL) -> String`, `func srcMtime(_ ext4Path: String) -> Date`, `func shell(_ cmd: String) -> Int32`. Di test, `v` = `Volume.openImage(Fixtures.trixie)` dan `dirtyVolume` = versi dirty.img. Root `"/"` berarti seluruh disk, dan `DiskSettings.backupRoot == nil` diperlakukan sebagai `"/"`.
- Fixture, yang dipakai semua task berikutnya:
  - `build/src/`: pohon sumber, yaitu `immich/library/{library,upload,thumbs,encoded-video}/` masing-masing dengan file `.immich`; `immich/library/library/admin/2026/07/01/IMG_0001.heic` (100 KB acak), `.../2026/07/02/IMG_0002.heic`, `.../2026/08/01/IMG_5772.heic`; `big/huge.bin` (sparse 5 GiB, `truncate -s 5G`); `bigdir/f00000..f19999` (file kosong); `names/café.txt` (NFC); symlink `links/l -> ../names`.
  - `build/trixie.img`: 512 MiB, `mkfs.ext4 -q -F -b 4096 -I 256 -N 40000 -O has_journal,extent,huge_file,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize,orphan_file -L SSDTEST -U 11111111-2222-3333-4444-555555555555 -d build/src`. Setelah itu, lewat `debugfs -w -f <cmdfile>`, tambahkan: `names/A.jpg` dan `names/a.jpg` (isi berbeda), `names/café.txt` versi NFD (`cafe\xcc\x81.txt`, isi berbeda), dan `names/bad\xff.txt`.
  - `build/dirty.img`: salinan `trixie.img` + `debugfs -w -R "feature needs_recovery"`.
  - Script memanggil `brew install e2fsprogs` jika `$(brew --prefix e2fsprogs)/sbin/mkfs.ext4` belum ada.

- [ ] **Step 1:** Vendor lwext4 dari `https://github.com/gkostka/lwext4` (commit terbaru `master`). Salin `src/*.c` ke `Sources/CLwext4/src/` dan `include/**` ke `Sources/CLwext4/include/`. Catat hash commit di `VERSION`, dan baca lisensi tiap file untuk `LICENSE` (tandai file GPL jika ada, spec §10.3).
- [ ] **Step 2:** `Package.swift`: platform `.macOS(.v14)`, target C `CLwext4` (`publicHeadersPath: "include"`, define `CONFIG_USE_DEFAULT_CFG=1`, `CONFIG_DEBUG_PRINTF=0`, `CONFIG_DEBUG_ASSERT=0`, `CONFIG_JOURNALING_ENABLE=1`, `CONFIG_META_CSUM_ENABLE=1`, `CONFIG_EXT4_MOUNTPOINTS_COUNT=4`, `CONFIG_EXT4_BLOCKDEVS_COUNT=4`), target `Ext4Kit` (bergantung pada `CLwext4`), test target `Ext4KitTests`. Tambal compile error lwext4 seminimal mungkin dan catat setiap tambalan di `VERSION`.
- [ ] **Step 3:** Tulis `make-fixtures.sh` sesuai spesifikasi fixture di atas, jalankan, lalu pastikan `$(brew --prefix e2fsprogs)/sbin/dumpe2fs -h Tests/Fixtures/build/trixie.img | grep features` memuat `metadata_csum 64bit orphan_file`.
- [ ] **Step 4: Tulis test spike yang gagal**

```swift
@Test @LwExt4 func mountsTrixieDefaultsReadOnly() throws {
    let fd = open(Fixtures.trixie.path, O_RDONLY)
    let size = try FileManager.default.attributesOfItem(atPath: Fixtures.trixie.path)[.size] as! UInt64
    let bd = fd_blockdev_create(fd, 512, size / 512)!
    #expect(ext4_device_register(bd, "spike") == EOK)
    #expect(ext4_mount("spike", "/spike/", true) == EOK)
    var dir = ext4_dir(); #expect(ext4_dir_open(&dir, "/spike/immich/library/library/admin/2026/08/01/") == EOK)
    var names: [String] = []
    while let e = ext4_dir_entry_next(&dir) { names.append(/* nama dari e.pointee */) }
    #expect(names.contains("IMG_5772.heic"))
    ext4_dir_close(&dir); ext4_umount("/spike/"); ext4_device_unregister("spike")
    fd_blockdev_destroy(bd); close(fd)
}
```

- [ ] **Step 5:** `swift test --filter SpikeTests`. Diharapkan PASS. **Kalau mount gagal** (misalnya karena `orphan_file`/`orphan_present` atau checksum), perbaiki lwext4 hanya untuk jalur **baca**, catat di `VERSION`, lalu ulangi. Jangan lanjut ke Task 2 sebelum lulus. Kalau perbaikannya ternyata besar, berhenti dan laporkan.
- [ ] **Step 6:** Commit `feat: vendor lwext4, fd blockdev shim, trixie fixtures`.

---

### Task 2: Superblock

**Files:**
- Create: `Sources/Ext4Kit/Superblock.swift`, `Tests/Ext4KitTests/SuperblockTests.swift`

**Interfaces:**
- Produces:
```swift
public struct Superblock: Sendable, Equatable {
    public init(bytes: some Collection<UInt8>) throws(Ext4Error)  // 1024 byte mulai offset 1024 disk
    public static func read(fd: Int32, sectorSize: Int) throws(Ext4Error) -> Superblock // baca 4096 byte dari offset 0 (aman untuk alignment rdisk)
    public let uuid: UUID, label: String, blockSize: Int, blockCount: UInt64
    public let compat: UInt32, incompat: UInt32, roCompat: UInt32
    public var isClean: Bool   // (s_state & 1) != 0 && (incompat & 0x4) == 0
}
public enum Ext4Error: Error, Equatable { case notExt4, io(Int32), unsupported(String), notFound(String), notClean, destinationMissing, cancelled, diskDisconnected, destinationFull }
```
- Offset (relatif ke awal superblock): `s_blocks_count_lo` 0x04, `s_log_block_size` 0x18, `s_state` 0x3A, `s_magic` 0x38 (= 0xEF53), `feature_compat` 0x5C, `feature_incompat` 0x60, `feature_ro_compat` 0x64, `s_uuid` 0x68 (16), `s_volume_name` 0x78 (16, NUL-padded), `s_blocks_count_hi` 0x150 (hanya jika incompat & 0x80). Semua little-endian.

- [ ] **Step 1: Tulis test yang gagal**

```swift
@Test func parsesTrixieFixture() throws {
    let sb = try Superblock.read(fd: open(Fixtures.trixie.path, O_RDONLY), sectorSize: 512)
    #expect(sb.uuid == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    #expect(sb.label == "SSDTEST"); #expect(sb.blockSize == 4096)
    #expect(sb.blockCount == 131072); #expect(sb.isClean)
    #expect(sb.incompat & 0x80 != 0)   // 64bit
}
@Test func dirtyFixtureIsNotClean() throws { #expect(try !Superblock.read(fd: open(Fixtures.dirty.path, O_RDONLY), sectorSize: 512).isClean) }
@Test func rejectsNonExt4() { #expect(throws: Ext4Error.notExt4) { try Superblock(bytes: [UInt8](repeating: 0, count: 1024)) } }
```

- [ ] **Step 2:** `swift test --filter SuperblockTests` → FAIL (tipe belum ada).
- [ ] **Step 3:** Implementasikan sesuai Interfaces.
- [ ] **Step 4:** `swift test --filter SuperblockTests` → PASS.
- [ ] **Step 5:** Commit `feat: parse ext4 superblock`.

---

### Task 3: Volume (wrapper baca lwext4)

**Files:**
- Create: `Sources/Ext4Kit/Volume.swift`, `Tests/Ext4KitTests/VolumeTests.swift`

**Interfaces:**
- Consumes: `fd_blockdev_create/destroy`, `Superblock`, `@LwExt4`, `Ext4Error`.
- Produces:
```swift
public struct Entry: Hashable, Sendable {
    public enum Kind: Sendable { case file, directory, symlink, other }
    public let name: String          // decode lossy untuk tampilan
    public let path: String          // absolut di fs, mis. "/immich/library"
    public let kind: Kind, size: UInt64, mtime: Date
    public let hasValidName: Bool    // false jika nama bukan UTF-8 valid
}
@LwExt4 public final class Volume {
    public static func openImage(_ url: URL) throws(Ext4Error) -> Volume
    public static func open(fd: Int32) throws(Ext4Error) -> Volume  // fd milik Volume; ukuran sektor/jumlah via ioctl DKIOCGETBLOCKSIZE/DKIOCGETBLOCKCOUNT, fallback fstat untuk file biasa
    public let superblock: Superblock
    public func list(_ path: String) throws(Ext4Error) -> [Entry]   // tanpa "." dan "..", urut nama (localizedStandardCompare)
    public func entry(_ path: String) throws(Ext4Error) -> Entry
    public func read(_ path: String, _ body: (UnsafeRawBufferPointer) throws -> Void) throws  // potongan 1 MiB
    public func close()   // umount, unregister, destroy, close(fd); idempoten
}
```
- Superblock dibaca **sebelum** mount. Mount lwext4 selalu `read_only = true`, dengan nama device/mountpoint unik per instance (`"v\(n)"`, `"/v\(n)/"`).
- size/mtime diambil dari `ext4_raw_inode_fill` + `ext4_inode_get_size` / `ext4_inode_get_modif_time`, bukan `ext4_fopen` per entry.
- Entry dengan `hasValidName == false` tetap muncul di `list`, tapi `read` untuknya melempar `.unsupported("nama bukan UTF-8 valid")`.

- [ ] **Step 1: Tulis test yang gagal**

```swift
@Test @LwExt4 func listsAndReadsIdenticalToSource() throws {
    let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
    let p = "/immich/library/library/admin/2026/08/01/IMG_5772.heic"
    var data = Data(); try v.read(p) { data.append(contentsOf: $0) }
    #expect(data == (try Data(contentsOf: Fixtures.srcTree.appending(path: String(p.dropFirst())))))
    let e = try v.entry(p)
    #expect(e.kind == .file && e.size == UInt64(data.count))
    #expect(abs(e.mtime.timeIntervalSince(try srcMtime(p))) < 1)
}
@Test @LwExt4 func hugeSparseFileSize() throws { /* entry("/big/huge.bin").size == 5 * 1<<30 */ }
@Test @LwExt4 func symlinkKind() throws { /* entry("/links/l").kind == .symlink */ }
@Test @LwExt4 func invalidUtf8NameListedButUnreadable() throws {
    /* list("/names") memuat entry dengan hasValidName == false; read(e.path) melempar .unsupported */
}
@Test @LwExt4 func listsTwentyThousandEntriesFast() throws {   // Review Focus 4
    let v = try Volume.openImage(Fixtures.trixie); defer { v.close() }
    let t = ContinuousClock.now; let es = try v.list("/bigdir")
    #expect(es.count == 20000); #expect(ContinuousClock.now - t < .seconds(2))
}
@Test @LwExt4 func readOnlyLeavesImageByteIdentical() throws {   // anti-tujuan #1
    let before = sha256(Fixtures.trixie)
    let v = try Volume.openImage(Fixtures.trixie); _ = try v.list("/bigdir"); try v.read("/names/A.jpg") { _ in }; v.close()
    #expect(sha256(Fixtures.trixie) == before)
}
@Test @LwExt4 func twoVolumesAtOnce() throws { /* buka trixie & dirty bersamaan, keduanya bisa list("/") */ }
```

- [ ] **Step 2:** `swift test --filter VolumeTests` → FAIL.
- [ ] **Step 3:** Implementasikan `Volume` sesuai Interfaces.
- [ ] **Step 4:** `swift test --filter VolumeTests` → PASS.
- [ ] **Step 5:** Commit `feat: read-only Volume over lwext4`.

---

### Task 4: Model pilihan (Selection)

**Files:**
- Create: `Sources/Ext4Kit/Selection.swift`, `Tests/Ext4KitTests/SelectionTests.swift`

**Interfaces:**
- Produces:
```swift
public struct Selection: Codable, Equatable, Sendable {
    public enum State: Sendable { case on, off, mixed }
    public private(set) var included: Set<String>   // path relatif ke akar backup, tanpa "/" di depan
    public private(set) var excluded: Set<String>
    public init()
    public func isSelected(_ path: String) -> Bool   // leluhur/diri terdekat yang tercatat menentukan; default off
    public func state(of path: String) -> State      // mixed jika ada turunan tercatat yang berlawanan dengan isSelected(path)
    public mutating func set(_ path: String, _ on: Bool)  // hapus semua catatan turunan path, lalu catat path hanya jika berbeda dari status induknya
    public var isEmpty: Bool { included.isEmpty }
}
```

- [ ] **Step 1: Tulis test yang gagal**

```swift
@Test func checkingFolderSelectsDescendants() { var s = Selection(); s.set("admin/2026/07", true)
    #expect(s.isSelected("admin/2026/07/01/IMG_0001.heic")); #expect(!s.isSelected("admin/2026/08"))
    #expect(s.state(of: "admin/2026") == .mixed); #expect(s.state(of: "admin/2026/07") == .on) }
@Test func uncheckInsideCheckedFolderBecomesExclusion() { var s = Selection(); s.set("admin", true); s.set("admin/2026/08", false)
    #expect(s.excluded == ["admin/2026/08"]); #expect(s.state(of: "admin") == .mixed); #expect(s.isSelected("admin/2027")) } // folder baru ikut
@Test func recheckingParentClearsChildRecords() { var s = Selection(); s.set("admin/2026/08", true); s.set("admin/2026/07", true); s.set("admin", true)
    #expect(s.included == ["admin"] && s.excluded.isEmpty) }
@Test func uncheckingEverythingIsEmpty() { var s = Selection(); s.set("admin", true); s.set("admin", false); #expect(s.isEmpty && s.excluded.isEmpty) }
@Test func prefixIsNotAncestor() { var s = Selection(); s.set("admin/2026/0", true); #expect(!s.isSelected("admin/2026/07")) }
@Test func roundTripsJSON() throws { var s = Selection(); s.set("a", true); s.set("a/b", false)
    #expect(try JSONDecoder().decode(Selection.self, from: JSONEncoder().encode(s)) == s) }
```

- [ ] **Step 2:** `swift test --filter SelectionTests` → FAIL.
- [ ] **Step 3:** Implementasikan. Pengecekan leluhur dilakukan per komponen path, bukan prefix string.
- [ ] **Step 4:** `swift test --filter SelectionTests` → PASS.
- [ ] **Step 5:** Commit `feat: selection model with inclusions and exclusions`.

---

### Task 5: BackupPlanner

**Files:**
- Create: `Sources/Ext4Kit/BackupPlanner.swift`, `Tests/Ext4KitTests/BackupPlannerTests.swift`

**Interfaces:**
- Consumes: `Volume`, `Entry`, `Selection`, `Ext4Error`.
- Produces:
```swift
public struct BackupItem: Sendable, Equatable {
    public enum Action: Sendable, Equatable { case copy(to: String), skip, conflict(to: String), fail(String) }
    public let sourcePath: String      // absolut di ext4
    public let relativePath: String    // relatif ke akar
    public let size: UInt64, mtime: Date
    public let action: Action          // `to` relatif ke folder tujuan
}
public struct BackupPlan: Sendable {
    public let items: [BackupItem]
    public let missingSelections: [String]  // path tersimpan yang tidak ada lagi di disk
    public let availableBytes: Int64
    public var bytesToCopy: UInt64          // jumlah size untuk .copy dan .conflict
    public var hasEnoughSpace: Bool         // bytesToCopy <= availableBytes
    public var counts: (copy: Int, skip: Int, conflict: Int, fail: Int)
}
@LwExt4 public func enumerateSelected(_ v: Volume, root: String, selection: Selection,
                                      visit: (Entry, _ relativePath: String) throws -> Void) throws -> [String] // return missing; menelusuri hanya cabang yang isSelected atau state == .mixed
@LwExt4 public func makePlan(_ v: Volume, root: String, selection: Selection, destination: URL) throws(Ext4Error) -> BackupPlan
```
- Urutan aturan: `!v.superblock.isClean` → throw `.notClean`. Tujuan tidak ada atau bukan direktori → throw `.destinationMissing` (**jangan pernah** membuat folder tujuan itu sendiri). Symlink/other → `.fail("dilewati: symlink")` / `.fail("dilewati: bukan file biasa")`. Nama tidak valid → `.fail("nama bukan UTF-8 valid")`.
- Klaim nama: simpan `Set<String>` berisi key `relativePath.precomposedStringWithCanonicalMapping.lowercased()` untuk setiap tujuan yang sudah diklaim dalam plan ini. Kandidat nama (`nama`, `nama (2)`, `nama (3)`, …) diperiksa berurutan: jika sudah diklaim → lanjut ke kandidat berikutnya; jika ada di disk dan cocok (ukuran + mtime ±2 detik) → `.skip`; jika ada di disk tapi tidak cocok → lanjut; jika belum ada → `.copy` untuk kandidat pertama, atau `.conflict` untuk kandidat ≥ (2). Kandidat terpilih lalu diklaim. `// ponytail: lipat huruf selalu, juga di tujuan case-sensitive; hasilnya konsisten di kedua jenis volume`.
- `availableBytes` diambil dari `volumeAvailableCapacityForImportantUsageKey`.

- [ ] **Step 1: Tulis test yang gagal** (akar `"/"` = seluruh disk; `sel("")` = semua isi akar; tujuan = tmp dir baru)

```swift
@Test @LwExt4 func freshDestinationCopiesSelection() throws {
    let p = try makePlan(v, root: "/immich/library/library", selection: sel("admin/2026/07"), destination: tmp)
    #expect(p.items.map(\.action) == [.copy(to: "admin/2026/07/01/IMG_0001.heic"), .copy(to: "admin/2026/07/02/IMG_0002.heic")])
}
@Test @LwExt4 func matchingFileIsSkipped() throws { /* salin IMG_0001 manual ke tmp + set mtime sumber+1s → .skip */ }
@Test @LwExt4 func differingFileBecomesConflictTwo() throws { /* file di tmp beda ukuran → .conflict(to: "admin/2026/07/01/IMG_0001 (2).heic") */ }
@Test @LwExt4 func earlierConflictCopyMatchingIsSkipped() throws { /* tmp punya versi beda + "IMG_0001 (2).heic" yang cocok → .skip */ }
@Test @LwExt4 func caseCollisionInSameRun() throws {
    let p = try makePlan(v, root: "/names", selection: sel("A.jpg", "a.jpg"), destination: tmp)
    #expect(Set(p.items.map(\.action)) == [.copy(to: "A.jpg"), .conflict(to: "a (2).jpg")])
}
@Test @LwExt4 func unicodeNormalizationCollision() throws {   // Review Focus 5
    let p = try makePlan(v, root: "/names", selection: sel(""), destination: tmp)
    #expect(p.items.filter { $0.relativePath.lowercased().hasPrefix("caf") }.map(\.action).contains(.conflict(to: "café (2).txt")))
}
@Test @LwExt4 func symlinkAndBadNameFail() throws { /* root "/", sel("links","names") → items symlink .fail("dilewati: symlink"), bad\xff .fail("nama bukan UTF-8 valid") */ }
@Test @LwExt4 func dirtyVolumeRefused() throws { #expect(throws: Ext4Error.notClean) { try makePlan(dirtyVolume, root: "/", selection: sel(""), destination: tmp) } }
@Test @LwExt4 func missingDestinationRefusedAndNotCreated() throws {   // Review Focus 3
    let d = URL(filePath: "/tmp/ext4reader-tidak-ada-\(UUID())")
    #expect(throws: Ext4Error.destinationMissing) { try makePlan(v, root: "/", selection: sel("names"), destination: d) }
    #expect(!FileManager.default.fileExists(atPath: d.path))
}
@Test @LwExt4 func missingSelectionReported() throws { /* sel("admin/2025") → missingSelections == ["admin/2025"] */ }
@Test @LwExt4 func excludedBranchNotVisited() throws { /* sel admin minus admin/2026/08 → tidak ada IMG_5772 */ }
```

- [ ] **Step 2:** `swift test --filter BackupPlannerTests` → FAIL.
- [ ] **Step 3:** Implementasikan sesuai Interfaces dan aturan di atas.
- [ ] **Step 4:** `swift test --filter BackupPlannerTests` → PASS.
- [ ] **Step 5:** Commit `feat: incremental backup planner`.

---

### Task 6: BackupRunner

**Files:**
- Create: `Sources/Ext4Kit/BackupRunner.swift`, `Tests/Ext4KitTests/BackupRunnerTests.swift`

**Interfaces:**
- Consumes: `BackupPlan`, `BackupItem`, `Volume.read`.
- Produces:
```swift
public struct BackupProgress: Sendable { public let filesDone, filesTotal: Int; public let bytesDone, bytesTotal: UInt64; public let currentPath: String }
public struct BackupReport: Sendable {
    public var copied: [String], skipped: Int, conflicts: [(source: String, dest: String)], failures: [(path: String, message: String)]
    public var stopReason: Ext4Error?        // .cancelled, .diskDisconnected, .destinationFull
    public func text() -> String              // laporan bahasa Indonesia, bisa disimpan ke .txt
}
@LwExt4 public func runBackup(_ plan: BackupPlan, volume: Volume, destination: URL,
                              progress: (BackupProgress) -> Void, isCancelled: () -> Bool) -> BackupReport
```
- Per item `.copy`/`.conflict`: buat folder induk, tulis ke `.<nama>.partial` (`FileHandle`, potongan dari `Volume.read`), `setAttributes(.modificationDate)`, lalu `renamex_np(partial, final, RENAME_EXCL)`. Jika ada error, hapus partial. `.fail` masuk ke `failures`, `.skip` menambah `skipped`.
- `isCancelled()` dicek setiap potongan. Saat batal: hapus partial, `stopReason = .cancelled`, berhenti.
- Error baca dengan errno `EIO`/`ENXIO`/`ENODEV`/`EBADF` pada **2 file berturut-turut** → `stopReason = .diskDisconnected`, berhenti. Error tulis `ENOSPC` → `.destinationFull`, berhenti. Error lain → masuk `failures`, lanjut.
- Ini termasuk bagian `Volume.read` yang perlu membawa errno lwext4 sebagai `Ext4Error.io(errno)`.

- [ ] **Step 1: Tulis test yang gagal**

```swift
@Test @LwExt4 func endToEndMatchesSourceAndRerunSkipsAll() throws {
    let plan = try makePlan(v, root: "/immich/library/library", selection: sel("admin"), destination: tmp)
    let r = runBackup(plan, volume: v, destination: tmp, progress: { _ in }, isCancelled: { false })
    #expect(r.failures.isEmpty && r.stopReason == nil)
    #expect(shell("diff -r \(Fixtures.srcTree.path)/immich/library/library/admin \(tmp.path)/admin --exclude=.immich") == 0)
    #expect(mtime(tmp/"admin/2026/08/01/IMG_5772.heic") ≈ entry mtime)   // ±1s
    let again = try makePlan(v, root: "/immich/library/library", selection: sel("admin"), destination: tmp)
    #expect(again.counts.copy == 0 && again.counts.conflict == 0)
}
@Test @LwExt4 func neverOverwritesExistingFile() throws { /* tmp punya IMG_0001 berbeda → setelah run isinya tetap sama, dan "(2)" berisi data sumber */ }
@Test @LwExt4 func cancelLeavesNoPartial() throws {
    /* isCancelled true setelah potongan pertama big file (pilih /big/huge.bin) → stopReason == .cancelled, tidak ada file ".partial" dan "huge.bin" di tmp */
}
@Test @LwExt4 func diskDisconnectStopsCleanly() throws {   // Review Focus 1
    /* salin trixie.img ke tmp2, buka Volume dari salinan; di progress callback setelah file pertama: truncate(salinan, 0)
       → stopReason == .diskDisconnected, tidak ada ".partial" di tujuan */
}
@Test @LwExt4 func destinationFullStopsCleanly() throws {   // Review Focus 2
    /* hdiutil create -size 2m -fs HFS+ -volname T img; hdiutil attach -nobrowse; tujuan = mountpoint; plan dibuat dengan
       huge.bin? (tidak muat) → paksa jalankan runBackup tanpa cek hasEnoughSpace → stopReason == .destinationFull, tidak ada ".partial"; detach di defer */
}
@Test func reportTextListsSections() { /* text() memuat "Disalin:", "Dilewati:", "Konflik:", "Gagal:" */ }
```

- [ ] **Step 2:** `swift test --filter BackupRunnerTests` → FAIL.
- [ ] **Step 3:** Implementasikan sesuai Interfaces.
- [ ] **Step 4:** `swift test --filter BackupRunnerTests` → PASS, lalu `swift test` (semua) → PASS.
- [ ] **Step 5:** Commit `feat: backup runner with atomic partial files`.

---

### Task 7: DiskSettings + saran akar Immich

**Files:**
- Create: `Sources/Ext4Kit/DiskSettings.swift`, `Sources/Ext4Kit/Immich.swift`, `Tests/Ext4KitTests/DiskSettingsTests.swift`

**Interfaces:**
- Produces:
```swift
public struct DiskSettings: Codable, Equatable, Sendable {
    public var backupRoot: String?       // path absolut ext4
    public var destination: String?      // path absolut di Mac
    public var selection: Selection
    public static let defaultDirectory: URL   // ~/Library/Application Support/Ext4Reader
    public static func load(uuid: UUID, from dir: URL = defaultDirectory) -> DiskSettings   // tidak ada atau rusak → kosong
    public func save(uuid: UUID, to dir: URL = defaultDirectory) throws   // <dir>/<uuid>.json, tulis atomik
}
@LwExt4 public func suggestedImmichRoot(_ v: Volume) -> String?
// cari direktori D dengan kedalaman ≤ 4 yang punya subfolder "library" dan "upload" serta "thumbs" atau "encoded-video"; hasil "D/library". BFS, hanya direktori.
```

- [ ] **Step 1: Tulis test yang gagal**

```swift
@Test func settingsRoundTripPerUUID() throws { /* save lalu load di tmp → sama; UUID lain → DiskSettings kosong */ }
@Test func corruptFileLoadsEmpty() throws { /* tulis "x" ke <uuid>.json → load == kosong */ }
@Test @LwExt4 func suggestsImmichLibrary() throws { #expect(suggestedImmichRoot(v) == "/immich/library/library") }
```

- [ ] **Step 2:** `swift test --filter DiskSettingsTests` → FAIL.
- [ ] **Step 3:** Implementasikan.
- [ ] **Step 4:** `swift test --filter DiskSettingsTests` → PASS.
- [ ] **Step 5:** Commit `feat: per-disk settings and Immich root suggestion`.

---

### Task 8: App — buka image, pohon bercentang, akar backup

**Files:**
- Create: `project.yml`, `App/Ext4ReaderApp.swift`, `App/BrowserModel.swift`, `App/SidebarView.swift`, `App/TreeView.swift`, `App/BottomBar.swift`

**Interfaces:**
- Consumes: `Volume`, `Selection`, `DiskSettings`, `suggestedImmichRoot`, `enumerateSelected`.
- Produces:
```swift
@MainActor @Observable final class BrowserModel {
    struct Source: Identifiable { let id: String; let title: String; var status: Status; var volume: Volume? }  // id = path image atau BSD name
    enum Status { case readOnly, notClean, unsupported(String), needsOpen }
    var sources: [Source]; var selectedSourceID: String?
    var settings: DiskSettings                 // milik source terpilih; disimpan otomatis setiap kali berubah
    var totals: (files: Int, bytes: UInt64)?   // nil = "menghitung…"
    func openImage(_ url: URL) async
    func addOpened(fd: Int32, id: String, title: String) async   // dipakai Task 10
    func children(of path: String) async -> [Entry]
    func toggle(_ path: String)                // path absolut → relatif ke akar; tidak ada efek di luar akar
    func setBackupRoot(_ path: String)         // jika sebelumnya sudah ada tujuan + akar lain → tampilkan peringatan spec §6a
}
```
- `project.yml`: target `Ext4Reader` (application, macOS 14.0, `ENABLE_APP_SANDBOX: NO`, `ARCHS: $(ARCHS_STANDARD)`), dependency pada paket lokal `Ext4Kit`. Build: `xcodegen && xcodebuild -scheme Ext4Reader -configuration Debug build`.
- UI (spec §5): `NavigationSplitView`. Sidebar berisi sources dengan ikon status 🔒/⚠️/⛔ dan tombol "Buka image…" (NSOpenPanel). Detail berisi breadcrumb dan pohon `List` dengan `DisclosureGroup` yang memuat anak saat dibuka (lazy via `children(of:)`), kolom nama/ukuran (`ByteCountFormatter`)/tanggal, dan checkbox tiga status (`checkmark.square`, `square`, `minus.square`) yang nonaktif di luar akar. Menu konteks folder: "Jadikan akar backup". Akar ditandai dengan ikon bendera. Bar bawah: "Dipilih: N file · X GB" atau "menghitung…", dihitung ulang di `Task` lewat `enumerateSelected` dan dibatalkan jika pilihan berubah, plus tombol **Backup ke…** (aksinya di Task 9).
- Saat volume dibuka: muat `DiskSettings` dari UUID. Jika `backupRoot == nil` dan `suggestedImmichRoot` ada, tampilkan alert "Ini terlihat seperti library Immich. Jadikan `<path>` akar backup?" (Ya/Tidak).
- Layar kosong: "Colok SSD ext4. Jika macOS bilang disk tidak dapat dibaca, pilih **Ignore**."

- [ ] **Step 1:** Tulis `project.yml` dan app shell, lalu build: `xcodegen && xcodebuild -scheme Ext4Reader build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`.
- [ ] **Step 2:** Implementasikan `BrowserModel` dan view sesuai Interfaces.
- [ ] **Step 3: Cek manual** dengan `Tests/Fixtures/build/trixie.img`: buka image → alert saran Immich muncul → Ya → centang `admin/2026/07` → bar bawah menampilkan "Dipilih: 2 file · …" → `admin/2026` tampil ◩ → `/bigdir` terbuka tanpa freeze → tutup app, buka lagi image → pilihan dan akar masih ada.
- [ ] **Step 4:** Commit `feat: browser UI with tri-state tree and backup root`.

---

### Task 9: App — sheet backup (pratinjau, progress, laporan)

**Files:**
- Create: `App/BackupSheet.swift`
- Modify: `App/BrowserModel.swift` (tambah state backup), `App/BottomBar.swift`

**Interfaces:**
- Consumes: `makePlan`, `runBackup`, `BackupPlan`, `BackupProgress`, `BackupReport`, `DiskSettings.destination`.
- Produces: `BrowserModel.startBackup()`: jika `settings.destination` kosong, buka NSOpenPanel (pilih folder) dan simpan, lalu buat plan dan tampilkan sheet.
- Sheet memiliki 3 fase:
  1. **Pratinjau:** "N dipilih → X baru (GB), Y dilewati, Z konflik, W gagal", daftar `missingSelections` sebagai "hilang", dan ruang kosong. Tombol **Mulai** nonaktif jika `!hasEnoughSpace`. Tombol "Ganti tujuan…". Error `.notClean` → "Disk ini tidak dilepas dengan bersih. Mount lalu umount disk ini sekali di Linux." Error `.destinationMissing` → "Folder tujuan tidak ditemukan. Colok disk tujuan atau pilih folder lain."
  2. **Progress:** file x/y, byte, kecepatan (rata-rata bergerak 5 detik), sisa waktu, dan **Batal**. Progress di-throttle ke main actor maksimal 10×/detik.
  3. **Laporan:** ringkasan, alasan berhenti (`.diskDisconnected` → "Disk terputus", `.destinationFull` → "Disk tujuan penuh", `.cancelled` → "Dibatalkan"), daftar konflik/gagal, dan **Simpan laporan…** (NSSavePanel `.txt`, isi `report.text()`).

- [ ] **Step 1:** Implementasikan sesuai Interfaces, lalu build → `** BUILD SUCCEEDED **`.
- [ ] **Step 2: Cek manual** dengan trixie.img: backup `admin` ke folder baru → laporan "Disalin: 3" → backup lagi → pratinjau "0 baru, 3 dilewati". Buka dirty.img → pesan notClean muncul. Pilih `/big/huge.bin` → Batal di tengah → tidak ada `.partial` di tujuan.
- [ ] **Step 3:** Commit `feat: backup sheet with preview, progress and report`.

---

### Task 10: App — disk fisik (DiskArbitration + authopen)

**Files:**
- Create: `App/DiskWatcher.swift`, `App/RawDiskOpener.swift`
- Modify: `App/BrowserModel.swift`, `App/SidebarView.swift`

**Interfaces:**
- Consumes: `BrowserModel.addOpened(fd:id:title:)`, `Volume.open(fd:)`.
- Produces:
  - `final class DiskWatcher` memakai `DARegisterDiskAppearedCallback`/`DisappearedCallback` dan menghasilkan `Candidate { bsdName: String; title: String; size: Int64 }`. Kandidat = partisi dengan `kDADiskDescriptionMediaContentKey` sama dengan `0FC63DAF-8483-4772-8E79-3D69D8477DE4` atau `Linux`, **atau** whole disk eksternal tanpa partisi yang dikenali. `// ponytail: magic ext4 baru bisa dicek setelah authopen; kandidat yang ternyata bukan ext4 ditandai ⛔ setelah dibuka`.
  - `enum RawDiskOpener { static func openReadOnly(bsdName: String) throws -> Int32 }`: buat `socketpair`, jalankan `/usr/libexec/authopen -stdoutpipe /dev/r<bsdName>` dengan stdout ke salah satu ujung, terima fd via `recvmsg` (`SCM_RIGHTS`), lalu tunggu proses selesai. Status keluar ≠ 0 atau tanpa fd → error "Akses ditolak". Tidak pernah memakai flag `-w`/`-o`.
- Sidebar menampilkan kandidat sebagai `.needsOpen` ("Klik untuk membuka, perlu password admin"). Setelah dibuka, statusnya menjadi readOnly/notClean/unsupported. Saat disk dicabut, Volume ditutup dan source dihapus. Jika backup sedang jalan, runner akan berhenti dengan `.diskDisconnected` (Task 6).

- [ ] **Step 1:** Implementasikan, lalu build → `** BUILD SUCCEEDED **`.
- [ ] **Step 2: Cek manual dengan USB flash/SSD uji** (bukan SSD Immich): format di Linux atau lewat `mkfs.ext4` ke flash disk, colok → Ignore → muncul di sidebar → buka (dialog password) → pohon tampil → backup satu folder → `diff -r` cocok → cabut disk saat backup → "Disk terputus".
- [ ] **Step 3: Uji jaminan read-only pada disk uji:** `shasum -a 256 /dev/rdiskN` (sudo) sebelum dan sesudah sesi buka + backup → identik.
- [ ] **Step 4: Uji pada SSD Immich asli** (spec §9): buka → saran akar Immich → backup satu bulan → bandingkan jumlah file dengan `find` di server. Ukur kecepatan (spec §10.4) dan catat di laporan task.
- [ ] **Step 5:** Commit `feat: detect and open physical ext4 disks via authopen`.
