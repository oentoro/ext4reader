import Foundation

/// Pengaturan per disk, disimpan di `<dir>/<uuid>.json`.
public struct DiskSettings: Codable, Equatable, Sendable {
    public var backupRoot: String?       // path absolut ext4
    public var destination: String?      // path absolut di Mac
    public var selection: Selection

    public init(backupRoot: String? = nil, destination: String? = nil, selection: Selection = Selection()) {
        self.backupRoot = backupRoot
        self.destination = destination
        self.selection = selection
    }

    public static let defaultDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Ext4Reader", directoryHint: .isDirectory)

    /// Tidak ada atau rusak -> pengaturan kosong.
    public static func load(uuid: UUID, from dir: URL = defaultDirectory) -> DiskSettings {
        guard let data = try? Data(contentsOf: fileURL(uuid: uuid, in: dir)),
              let settings = try? JSONDecoder().decode(DiskSettings.self, from: data)
        else { return DiskSettings() }
        return settings
    }

    /// Tulis atomik; folder `dir` dibuat jika belum ada.
    public func save(uuid: UUID, to dir: URL = defaultDirectory) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.fileURL(uuid: uuid, in: dir), options: .atomic)
    }

    private static func fileURL(uuid: UUID, in dir: URL) -> URL {
        dir.appending(path: "\(uuid.uuidString).json")
    }
}
