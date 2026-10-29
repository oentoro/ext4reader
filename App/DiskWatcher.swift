import Foundation
import DiskArbitration

/// Mengamati disk yang muncul/hilang dan menyaring kandidat ext4.
/// ponytail: magic ext4 baru bisa dicek setelah authopen; kandidat yang ternyata bukan ext4 ditandai ⛔ setelah dibuka
@MainActor final class DiskWatcher {
    struct Candidate: Sendable { let bsdName: String; let title: String; let size: Int64 }

    var onAppear: (Candidate) -> Void = { _ in }
    var onDisappear: (String) -> Void = { _ in }

    private var session: DASession?
    nonisolated private static let linuxGUID = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"

    func start() {
        guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(s, nil, { disk, ctx in
            guard let ctx else { return }
            guard let c = DiskWatcher.candidate(disk) else { return }
            let w = Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { w.onAppear(c) }
        }, ctx)
        DARegisterDiskDisappearedCallback(s, nil, { disk, ctx in
            guard let ctx, let n = DADiskGetBSDName(disk) else { return }
            let name = String(cString: n)
            let w = Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { w.onDisappear(name) }
        }, ctx)
        DASessionSetDispatchQueue(s, .main)
    }

    nonisolated private static func candidate(_ disk: DADisk) -> Candidate? {
        guard let n = DADiskGetBSDName(disk),
              let d = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        let name = String(cString: n)
        if d[kDADiskDescriptionVolumePathKey as String] != nil { return nil }   // sudah ter-mount
        let content = d[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let whole = d[kDADiskDescriptionMediaWholeKey as String] as? Bool ?? false
        let internalDisk = d[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true
        let isLinux = content.uppercased() == linuxGUID || content == "Linux"
        let isBareExternal = whole && !internalDisk && content.isEmpty
        guard isLinux || isBareExternal else { return nil }
        let size = (d[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
        let media = (d[kDADiskDescriptionMediaNameKey as String] as? String) ?? "Disk"
        return Candidate(bsdName: name, title: "\(media) (\(name))", size: size)
    }
}
