import Foundation
import Darwin

/// Everything that can go wrong while talking to adb or the tablet.
enum ADBError: LocalizedError, Equatable {
    case adbMissing
    case serverDown
    case fail(String)             // the adb server answered FAIL
    case device(String)           // the tablet reported an error
    case io(String)               // the connection broke
    case protocolError(String)
    case timeout
    case cancelled
    case local(String)            // problem on the Mac side

    var errorDescription: String? {
        switch self {
        case .adbMissing:           return "Не найден adb (Android Platform Tools)"
        case .serverDown:           return "adb-сервер не запущен"
        case .fail(let message):    return ADBError.humanize(message)
        case .device(let message),
             .io(let message),
             .protocolError(let message),
             .local(let message):   return message
        case .timeout:              return "Планшет не отвечает"
        case .cancelled:            return "Отменено"
        }
    }

    /// Turns adb's English messages into something a person can act on.
    static func humanize(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("unauthorized") {
            return "Планшет ещё не разрешил доступ — нажмите «Разрешить» в окне «Разрешить отладку по USB?» на его экране"
        }
        if lower.contains("offline") { return "Планшет не отвечает. Переподключите кабель" }
        if lower.contains("no devices") || (lower.contains("device") && lower.contains("not found")) {
            return "Планшет отключился"
        }
        if lower.contains("no space left") { return "На планшете закончилось место" }
        if lower.contains("permission denied") { return "Нет доступа (Permission denied)" }
        if lower.contains("read-only file system") { return "Этот носитель только для чтения" }
        if lower.contains("file exists") { return "Такое имя уже занято" }
        if lower.contains("no such file") { return "Файл или папка не найдены" }
        if lower.contains("connection refused") {
            return "Планшет не принимает подключение по Wi-Fi — скорее всего, он перезагружался"
        }
        return text
    }
}

/// Blocking TCP connection to the local adb server (127.0.0.1:5037).
///
/// The server speaks "smart socket" framing: a request is 4 hex digits of
/// length followed by the service name, the answer starts with OKAY or FAIL.
/// After `host:transport:<serial>` the same socket is wired straight to the
/// tablet and carries whatever service is opened next (sync:, shell:, tcpip:).
final class ADBSocket {
    static let port: UInt16 = {
        if let raw = ProcessInfo.processInfo.environment["ANDROID_ADB_SERVER_PORT"],
           let value = UInt16(raw) { return value }
        return 5037
    }()

    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    init(timeout: TimeInterval = 0) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ADBError.io("socket(): \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            let code = errno
            Darwin.close(fd)
            if code == ECONNREFUSED { throw ADBError.serverDown }
            throw ADBError.io("Не удалось связаться с adb: \(String(cString: strerror(code)))")
        }
        self.fd = fd
        if timeout > 0 { setTimeout(timeout) }
    }

    deinit { close() }

    func setTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds),
                         tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Wakes up a thread blocked in read/write. Safe to call from any thread;
    /// the descriptor itself is closed only by its owner.
    func interrupt() {
        lock.lock(); defer { lock.unlock() }
        if !isClosed { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    // MARK: - Raw I/O

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { try write($0.baseAddress!, count: $0.count) }
    }

    func write(_ pointer: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.send(fd, pointer + offset, count - offset, 0)
            if n < 0 {
                if errno == EINTR { continue }
                throw Self.ioError(errno)
            }
            offset += n
        }
    }

    func read(into pointer: UnsafeMutableRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.recv(fd, pointer + offset, count - offset, 0)
            if n == 0 { throw ADBError.io("Связь с планшетом прервалась") }
            if n < 0 {
                if errno == EINTR { continue }
                throw Self.ioError(errno)
            }
            offset += n
        }
    }

    func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        if count > 0 {
            try data.withUnsafeMutableBytes { try read(into: $0.baseAddress!, count: count) }
        }
        return data
    }

    func readToEnd() throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, $0.count, 0) }
            if n == 0 { return out }
            if n < 0 {
                if errno == EINTR { continue }
                throw Self.ioError(errno)
            }
            out.append(contentsOf: buffer[0..<n])
        }
    }

    /// True when the peer has already sent something — used to notice an early
    /// FAIL (disk full, no permission) while a long upload is still streaming.
    func hasPendingInput() -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&p, 1, 0) > 0
    }

    private static func ioError(_ code: Int32) -> ADBError {
        if code == EAGAIN || code == EWOULDBLOCK { return .timeout }
        return .io("Связь с планшетом прервалась (\(String(cString: strerror(code))))")
    }

    // MARK: - Smart-socket framing

    func sendRequest(_ service: String) throws {
        let body = Data(service.utf8)
        guard body.count < 0x10000 else { throw ADBError.local("Слишком длинная команда для adb") }
        var packet = Data(String(format: "%04x", body.count).utf8)
        packet.append(body)
        try write(packet)
    }

    func readStatus() throws {
        let status = try read(4).tag()
        switch status {
        case "OKAY": return
        case "FAIL": throw ADBError.fail(try readString())
        default:     throw ADBError.protocolError("Неожиданный ответ adb: \(status)")
        }
    }

    func readString() throws -> String {
        let header = String(decoding: try read(4), as: UTF8.self)
        guard let length = Int(header, radix: 16) else {
            throw ADBError.protocolError("Неожиданный ответ adb: \(header)")
        }
        return String(decoding: try read(length), as: UTF8.self)
    }

    func open(_ service: String) throws {
        try sendRequest(service)
        try readStatus()
    }

    /// One-shot host query such as `host:version` or `host:connect:…`.
    static func query(_ service: String, timeout: TimeInterval = 15) throws -> String {
        let socket = try ADBSocket(timeout: timeout)
        defer { socket.close() }
        try socket.open(service)
        return try socket.readString()
    }

    /// A socket already switched to the given tablet with `service` opened on it.
    static func device(_ serial: String, service: String, timeout: TimeInterval = 0) throws -> ADBSocket {
        let socket = try ADBSocket(timeout: timeout)
        do {
            try socket.open("host:transport:\(serial)")
            try socket.open(service)
        } catch {
            socket.close()
            throw error
        }
        return socket
    }
}

// MARK: - Little-endian helpers for the binary sync / shell protocols

extension Data {
    func le32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func le64(_ offset: Int) -> UInt64 {
        UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32
    }

    /// Four-letter protocol tag such as "OKAY", "DATA", "DNT2".
    func tag(_ offset: Int = 0) -> String {
        String(decoding: self[(startIndex + offset)..<(startIndex + offset + 4)], as: UTF8.self)
    }

    mutating func appendLE32(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
