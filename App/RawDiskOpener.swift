import Foundation
import Darwin

struct RawDiskError: LocalizedError {
    var errorDescription: String? { "Akses ditolak" }
}

enum RawDiskOpener {
    /// Membuka `/dev/r<bsdName>` read-only lewat authopen (dialog password admin).
    /// Memblokir; panggil di luar main actor. Sengaja tanpa `-w`/`-o`.
    static func openReadOnly(bsdName: String) throws -> Int32 {
        var sv: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else { throw RawDiskError() }
        let (parent, child) = (sv[0], sv[1])
        _ = fcntl(parent, F_SETFD, FD_CLOEXEC)
        _ = fcntl(child, F_SETFD, FD_CLOEXEC)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        p.arguments = ["-stdoutpipe", "/dev/r\(bsdName)"]
        p.standardOutput = FileHandle(fileDescriptor: child, closeOnDealloc: false)
        do { try p.run() } catch { close(parent); close(child); throw RawDiskError() }
        close(child)   // tinggal ujung milik authopen; EOF terdeteksi jika ia keluar tanpa fd

        let fd = receiveFD(parent)
        close(parent)
        if let fd { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        p.waitUntilExit()
        guard p.terminationStatus == 0, let fd else {
            if let fd { close(fd) }
            throw RawDiskError()
        }
        return fd
    }

    private static func receiveFD(_ sock: Int32) -> Int32? {
        var byte: UInt8 = 0
        var cbuf = [UInt8](repeating: 0, count: 16)
        return withUnsafeMutablePointer(to: &byte) { bp in
            cbuf.withUnsafeMutableBytes { cb in
                var iov = iovec(iov_base: bp, iov_len: 1)
                return withUnsafeMutablePointer(to: &iov) { ip in
                    var msg = msghdr()
                    msg.msg_iov = ip; msg.msg_iovlen = 1
                    msg.msg_control = cb.baseAddress; msg.msg_controllen = socklen_t(cb.count)
                    var r: Int
                    repeat { r = recvmsg(sock, &msg, 0) } while r < 0 && errno == EINTR
                    guard r >= 0, msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size) else { return nil }
                    let h = cb.baseAddress!.load(as: cmsghdr.self)
                    let minLen = socklen_t(MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size)   // CMSG_LEN(4)
                    guard h.cmsg_level == SOL_SOCKET, h.cmsg_type == SCM_RIGHTS else { return nil }
                    // CMSG_DATA: tepat setelah header (12 byte, sudah selaras 4)
                    let fd = cb.baseAddress!.loadUnaligned(fromByteOffset: MemoryLayout<cmsghdr>.size, as: Int32.self)
                    if msg.msg_flags & MSG_CTRUNC != 0 || h.cmsg_len < minLen { Darwin.close(fd); return nil }
                    return fd
                }
            }
        }
    }
}
