import Testing
import Foundation
import CLwext4
@testable import Ext4Kit

@Suite struct SpikeTests {
    @Test @LwExt4 func mountsTrixieDefaultsReadOnly() throws {
        let fd = open(Fixtures.trixie.path, Darwin.O_RDONLY)
        #expect(fd >= 0)
        let size = try FileManager.default.attributesOfItem(atPath: Fixtures.trixie.path)[.size] as! UInt64
        let bd = fd_blockdev_create(fd, 512, size / 512)!
        #expect(ext4_device_register(bd, "spike") == EOK)
        #expect(ext4_mount("spike", "/spike/", true) == EOK)
        var dir = ext4_dir()
        #expect(ext4_dir_open(&dir, "/spike/immich/library/library/admin/2026/08/01/") == EOK)
        var names: [String] = []
        while let e = ext4_dir_entry_next(&dir) {
            let len = Int(e.pointee.name_length)
            let name = withUnsafeBytes(of: e.pointee.name) {
                String(decoding: $0.prefix(len), as: UTF8.self)
            }
            names.append(name)
        }
        #expect(names.contains("IMG_5772.heic"))
        ext4_dir_close(&dir); ext4_umount("/spike/"); ext4_device_unregister("spike")
        fd_blockdev_destroy(bd); close(fd)
    }

    @Test @LwExt4 func mountsSeededAndReadsFile() throws {
        let fd = open(Fixtures.seeded.path, Darwin.O_RDONLY)
        #expect(fd >= 0)
        let size = try FileManager.default.attributesOfItem(atPath: Fixtures.seeded.path)[.size] as! UInt64
        let bd = fd_blockdev_create(fd, 512, size / 512)!
        #expect(ext4_device_register(bd, "seeded") == EOK)
        defer { fd_blockdev_destroy(bd); close(fd) }
        #expect(ext4_mount("seeded", "/seeded/", true) == EOK)
        defer { ext4_umount("/seeded/"); ext4_device_unregister("seeded") }
        var dir = ext4_dir()
        #expect(ext4_dir_open(&dir, "/seeded/a/b/") == EOK)
        var found = false
        while let e = ext4_dir_entry_next(&dir) {
            let len = Int(e.pointee.name_length)
            if withUnsafeBytes(of: e.pointee.name, { String(decoding: $0.prefix(len), as: UTF8.self) }) == "f.txt" { found = true }
        }
        ext4_dir_close(&dir)
        #expect(found)
        var f = ext4_file()
        #expect(ext4_fopen(&f, "/seeded/a/b/f.txt", "rb") == EOK)
        var buf = [UInt8](repeating: 0, count: 64); var n = 0
        #expect(ext4_fread(&f, &buf, 64, &n) == EOK)
        ext4_fclose(&f)
        #expect(String(decoding: buf.prefix(n), as: UTF8.self) == "hello-seeded\n")
    }
}
