import Foundation
import CryptoKit
import Ext4Kit

enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/build")

    private static func file(_ name: String) -> URL {
        let u = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: u.path) else {
            fatalError("Jalankan Tests/Fixtures/make-fixtures.sh")
        }
        return u
    }
    static var trixie: URL { file("trixie.img") }
    static var seeded: URL { file("seeded.img") }
    static var dirty: URL { file("dirty.img") }
    static var srcTree: URL { file("src") }
}

/// Fresh temp folder, removed at process exit.
func tmpDir() -> URL {
    let u = FileManager.default.temporaryDirectory
        .appendingPathComponent("ext4kit-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    _ = TmpCleanup.hook
    TmpCleanup.dirs.withLock { $0.append(u) }
    return u
}

import os
enum TmpCleanup {
    static let dirs = OSAllocatedUnfairLock(initialState: [URL]())
    static let hook: Void = {
        atexit { TmpCleanup.dirs.withLock { $0.forEach { try? FileManager.default.removeItem(at: $0) } } }
    }()
}

func sha256(_ url: URL) -> String {
    var h = SHA256()
    let fh = try! FileHandle(forReadingFrom: url)
    defer { try? fh.close() }
    while let d = try! fh.read(upToCount: 1 << 20), !d.isEmpty { h.update(data: d) }
    return h.finalize().map { String(format: "%02x", $0) }.joined()
}

/// mtime of a file in the source tree, given its ext4 path ("/immich/...").
func srcMtime(_ ext4Path: String) -> Date {
    let p = Fixtures.srcTree.appendingPathComponent(ext4Path).path
    return try! FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as! Date
}

@discardableResult
func shell(_ cmd: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    try! p.run(); p.waitUntilExit()
    return p.terminationStatus
}

/// Selection that has each given path checked (`set(p, true)`).
func sel(_ paths: String...) -> Selection {
    var s = Selection()
    for p in paths { s.set(p, true) }
    return s
}
