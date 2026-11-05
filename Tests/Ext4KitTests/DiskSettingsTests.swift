import Testing
import Foundation
@testable import Ext4Kit

@Suite struct DiskSettingsTests {
    @Test func settingsRoundTripPerUUID() throws {
        let dir = tmpDir()
        let id = UUID()
        var s = DiskSettings()
        s.backupRoot = "/immich/library/library"
        s.destination = "/Volumes/Backup"
        s.selection = sel("admin/2026/07")
        try s.save(uuid: id, to: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "\(id.uuidString).json").path))
        #expect(DiskSettings.load(uuid: id, from: dir) == s)
        #expect(DiskSettings.load(uuid: UUID(), from: dir) == DiskSettings())
    }

    @Test func saveCreatesMissingDirectory() throws {
        let dir = tmpDir().appending(path: "nested/deeper")
        let id = UUID()
        var s = DiskSettings()
        s.destination = "/Volumes/Backup"
        try s.save(uuid: id, to: dir)
        #expect(DiskSettings.load(uuid: id, from: dir) == s)
    }

    @Test func corruptFileLoadsEmpty() throws {
        let dir = tmpDir()
        let id = UUID()
        try "x".write(to: dir.appending(path: "\(id.uuidString).json"), atomically: true, encoding: .utf8)
        #expect(DiskSettings.load(uuid: id, from: dir) == DiskSettings())
    }
}
