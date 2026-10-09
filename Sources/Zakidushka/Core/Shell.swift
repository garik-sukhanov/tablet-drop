import Foundation

/// Runs commands on the tablet. Uses the shell v2 protocol (separate stdout,
/// stderr and a real exit code) and falls back to the legacy shell on very
/// old Android versions.
enum Shell {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ link: Link, _ command: String, timeout: TimeInterval = 60) throws -> Output {
        if link.features.contains("shell_v2") {
            let socket = try ADBSocket.device(link.serial, service: "shell,v2,raw:" + command, timeout: timeout)
            defer { socket.close() }
            var out = Data(), err = Data()
            while true {
                // Packet: 1-byte stream id + u32 length + payload.
                let header = try socket.read(5)
                let payload = try socket.read(Int(header.le32(1)))
                switch header[header.startIndex] {
                case 1: out.append(payload)
                case 2: err.append(payload)
                case 3:
                    return Output(status: Int32(payload.first ?? 0),
                                  stdout: String(decoding: out, as: UTF8.self),
                                  stderr: String(decoding: err, as: UTF8.self))
                default: continue
                }
            }
        }

        let marker = "__zakidushka_exit__"
        let socket = try ADBSocket.device(link.serial, service: "shell:\(command); echo \(marker)$?", timeout: timeout)
        defer { socket.close() }
        let text = String(decoding: try socket.readToEnd(), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = text.range(of: marker, options: .backwards) else {
            return Output(status: 0, stdout: text, stderr: "")
        }
        let status = Int32(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let output = String(text[..<range.lowerBound])
        return Output(status: status, stdout: status == 0 ? output : "", stderr: status == 0 ? "" : output)
    }

    /// Runs a command and throws with its error text when it fails.
    @discardableResult
    static func check(_ link: Link, _ command: String, timeout: TimeInterval = 60) throws -> String {
        let result = try run(link, command, timeout: timeout)
        guard result.status == 0 else {
            var message = result.stderr.isEmpty ? result.stdout : result.stderr
            message = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty { message = "Команда на планшете завершилась с ошибкой \(result.status)" }
            throw ADBError.device(ADBError.humanize(message))
        }
        return result.stdout
    }

    /// POSIX single-quote escaping for the tablet's shell.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Splits `prefix 'a' 'b' …` into several commands so each stays well
    /// under the size of one adb packet.
    static func batches(_ prefix: String, _ arguments: [String], link: Link) -> [String] {
        let limit = link.features.contains("shell_v2") ? 16_000 : 3_500
        var commands: [String] = []
        var current = prefix
        var count = 0
        for argument in arguments {
            let piece = " " + quote(argument)
            if count > 0, current.utf8.count + piece.utf8.count > limit {
                commands.append(current)
                current = prefix
                count = 0
            }
            current += piece
            count += 1
        }
        if count > 0 { commands.append(current) }
        return commands
    }
}
