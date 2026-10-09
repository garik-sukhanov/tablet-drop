import Foundation
import Darwin

/// One entry of a directory listing, straight from the tablet.
struct RemoteEntry {
    var name: String
    var mode: UInt32
    var size: Int64
    var mtime: Date?

    var isDirectory: Bool { mode & 0o170000 == 0o040000 }
    var isRegular: Bool { mode & 0o170000 == 0o100000 }
    var isSymlink: Bool { mode & 0o170000 == 0o120000 }
}

/// The adb `sync:` service — listing, stat, push and pull.
///
/// One instance owns one socket; calls are synchronous and must not overlap.
/// Wire format (AOSP `file_sync_protocol.h`): every request is a 4-byte tag,
/// a little-endian u32 length and the payload. Large-file safe variants
/// (`LIS2`/`STA2`, 64-bit sizes) are used when the tablet supports them.
final class SyncSession {
    let serial: String
    private let socket: ADBSocket
    private let v2: Bool

    static let chunk = 64 * 1024                    // SYNC_DATA_MAX
    private static let dataTag = Array("DATA".utf8)

    init(link: Link) throws {
        serial = link.serial
        v2 = link.features.contains("ls_v2") && link.features.contains("stat_v2")
        socket = try ADBSocket.device(link.serial, service: "sync:")
    }

    func close() {
        try? request("QUIT", Data())
        socket.close()
    }

    /// Aborts a transfer running on another thread.
    func interrupt() { socket.interrupt() }

    // MARK: - Requests

    private func request(_ tag: String, _ payload: Data) throws {
        var packet = Data(tag.utf8)
        packet.appendLE32(UInt32(payload.count))
        packet.append(payload)
        try socket.write(packet)
    }

    private func request(_ tag: String, path: String) throws {
        let bytes = Data(path.utf8)
        guard bytes.count <= 1024 else { throw ADBError.local("Слишком длинный путь: \(path)") }
        try request(tag, bytes)
    }

    // MARK: - stat / list

    /// `stat()` on the tablet (symlinks are followed); nil when nothing is there.
    func stat(_ path: String) throws -> RemoteEntry? {
        let name = (path as NSString).lastPathComponent
        if v2 {
            try request("STA2", path: path)
            let reply = try socket.read(72)
            guard reply.tag() == "STA2" else { throw ADBError.protocolError("STA2: \(reply.tag())") }
            if reply.le32(4) != 0 { return nil }          // errno: ENOENT, EACCES…
            return RemoteEntry(name: name,
                               mode: reply.le32(24),
                               size: Int64(bitPattern: reply.le64(40)),
                               mtime: Self.date(Int64(bitPattern: reply.le64(56))))
        } else {
            try request("STAT", path: path)
            let reply = try socket.read(16)
            guard reply.tag() == "STAT" else { throw ADBError.protocolError("STAT: \(reply.tag())") }
            let mode = reply.le32(4)
            if mode == 0 { return nil }
            return RemoteEntry(name: name, mode: mode, size: Int64(reply.le32(8)),
                               mtime: Self.date(Int64(reply.le32(12))))
        }
    }

    /// Directory contents without "." and "..". Entries are lstat()-ed, so
    /// symlinks come back as links.
    func list(_ path: String) throws -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        if v2 {
            try request("LIS2", path: path)
            while true {
                let header = try socket.read(76)       // sync_dent_v2; DONE has the same size
                let tag = header.tag()
                if tag == "DONE" { break }
                guard tag == "DNT2" else { throw ADBError.protocolError("LIS2: \(tag)") }
                let name = String(decoding: try socket.read(Int(header.le32(72))), as: UTF8.self)
                if name == "." || name == ".." { continue }
                entries.append(RemoteEntry(name: name,
                                           mode: header.le32(24),
                                           size: Int64(bitPattern: header.le64(40)),
                                           mtime: Self.date(Int64(bitPattern: header.le64(56)))))
            }
        } else {
            try request("LIST", path: path)
            while true {
                let header = try socket.read(20)       // sync_dent_v1
                let tag = header.tag()
                if tag == "DONE" { break }
                guard tag == "DENT" else { throw ADBError.protocolError("LIST: \(tag)") }
                let name = String(decoding: try socket.read(Int(header.le32(16))), as: UTF8.self)
                if name == "." || name == ".." { continue }
                entries.append(RemoteEntry(name: name,
                                           mode: header.le32(4),
                                           size: Int64(header.le32(8)),
                                           mtime: Self.date(Int64(header.le32(12)))))
            }
        }
        return entries
    }

    private static func date(_ seconds: Int64) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }

    // MARK: - push

    /// Uploads one file. Missing parent folders are created by the tablet.
    /// `progress` gets the byte count sent so far and returns false to cancel;
    /// a cancelled or failed upload leaves no partial file behind (adbd removes it).
    func push(_ local: URL, to remote: String, progress: (Int64) -> Bool) throws {
        let fd = Darwin.open(local.path, O_RDONLY)
        guard fd >= 0 else {
            throw ADBError.local("Не удалось открыть «\(local.lastPathComponent)»: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(fd) }
        var info = Darwin.stat()
        fstat(fd, &info)
        let mtime = UInt32(clamping: Int(info.st_mtimespec.tv_sec))

        try request("SEND", path: "\(remote),\(0o100644)")

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 8 + Self.chunk, alignment: 8)
        defer { buffer.deallocate() }
        Self.dataTag.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: 4) }

        var sent: Int64 = 0
        var chunks = 0
        while true {
            let n = Darwin.read(fd, buffer + 8, Self.chunk)
            if n < 0 {
                if errno == EINTR { continue }
                throw ADBError.local("Не удалось прочитать «\(local.lastPathComponent)»: \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            buffer.storeBytes(of: UInt32(n).littleEndian, toByteOffset: 4, as: UInt32.self)
            try socket.write(buffer, count: 8 + n)
            sent += Int64(n)
            chunks += 1
            // The tablet answers only at the end, unless something broke —
            // then a FAIL is already waiting and there is no point streaming on.
            if chunks % 32 == 0, socket.hasPendingInput() {
                try readResult()
            }
            if !progress(sent) { throw ADBError.cancelled }
        }

        var done = Data("DONE".utf8)
        done.appendLE32(mtime)
        try socket.write(done)
        try readResult()
    }

    private func readResult() throws {
        let header = try socket.read(8)
        let length = Int(header.le32(4))
        switch header.tag() {
        case "OKAY":
            return
        case "FAIL":
            let message = String(decoding: try socket.read(length), as: UTF8.self)
            throw ADBError.device(ADBError.humanize(message))
        default:
            throw ADBError.protocolError("SEND: \(header.tag())")
        }
    }

    // MARK: - pull

    /// Downloads one file. On failure or cancel the partial local file is removed.
    func pull(_ remote: String, to local: URL, mtime: Date?, progress: (Int64) -> Bool) throws {
        // Create the local file first: once RECV is sent the tablet streams
        // data, and bailing out mid-stream would leave the protocol out of step.
        let fd = Darwin.open(local.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw ADBError.local("Не удалось создать «\(local.lastPathComponent)»: \(String(cString: strerror(errno)))")
        }
        var finished = false
        defer {
            Darwin.close(fd)
            if !finished { try? FileManager.default.removeItem(at: local) }
        }

        try request("RECV", path: remote)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 8)
        defer { buffer.deallocate() }
        var received: Int64 = 0

        while true {
            let header = try socket.read(8)
            let length = Int(header.le32(4))
            switch header.tag() {
            case "DATA":
                guard length <= Self.chunk else { throw ADBError.protocolError("RECV: блок \(length) байт") }
                try socket.read(into: buffer, count: length)
                var offset = 0
                while offset < length {
                    let n = Darwin.write(fd, buffer + offset, length - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw ADBError.local("Не удалось записать «\(local.lastPathComponent)»: \(String(cString: strerror(errno)))")
                    }
                    offset += n
                }
                received += Int64(length)
                if !progress(received) { throw ADBError.cancelled }
            case "DONE":
                finished = true
                if let mtime {
                    try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: local.path)
                }
                return
            case "FAIL":
                let message = String(decoding: try socket.read(length), as: UTF8.self)
                throw ADBError.device(ADBError.humanize(message))
            default:
                throw ADBError.protocolError("RECV: \(header.tag())")
            }
        }
    }
}
