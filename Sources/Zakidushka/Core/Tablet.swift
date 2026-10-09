import Foundation

/// Where to send a command: an adb transport serial plus what the tablet's
/// adbd supports on it.
struct Link: Hashable {
    var serial: String
    var features: Set<String>
}

/// One line of `adb devices -l`: a single way to reach a device. The same
/// tablet can be reachable twice — by cable and by Wi-Fi.
struct Transport: Hashable {
    enum Kind { case usb, wifi, emulator }

    var serial: String
    var state: String                 // device, unauthorized, offline, authorizing, connecting…
    var info: [String: String]        // usb, product, model, device, transport_id

    var kind: Kind {
        if serial.hasPrefix("emulator-") { return .emulator }
        if info["usb"] != nil { return .usb }
        if serial.contains("._adb-tls-connect.") || serial.contains(":") { return .wifi }
        return .usb
    }

    var isReady: Bool { state == "device" }

    /// Wireless-debugging connections (Android 11+) come over TLS on a random
    /// port; "adb tcpip" mode listens on 5555.
    var isTCPMode: Bool { kind == .wifi && serial.hasSuffix(":5555") }

    static func parse(_ text: String) -> [Transport] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { return nil }
            var info: [String: String] = [:]
            var state = [parts[1]]
            for part in parts.dropFirst(2) {
                if let colon = part.firstIndex(of: ":") {
                    info[String(part[..<colon])] = String(part[part.index(after: colon)...])
                } else if info.isEmpty {
                    state.append(part)                 // "no permissions"
                }
            }
            return Transport(serial: parts[0], state: state.joined(separator: " "), info: info)
        }
    }

    /// "adb-R58M90ABCDE-AbCdEf._adb-tls-connect._tcp" → "R58M90ABCDE".
    var serialFromServiceName: String? {
        guard serial.hasPrefix("adb-"), let end = serial.range(of: "._adb-tls-connect") else { return nil }
        let middle = serial[serial.index(serial.startIndex, offsetBy: 4)..<end.lowerBound]
        guard let dash = middle.lastIndex(of: "-") else { return nil }
        let value = String(middle[..<dash])
        return value.isEmpty ? nil : value
    }
}

/// What we learn from a tablet once it lets us in.
struct DeviceProps {
    var hardwareSerial: String
    var name: String
    var android: String
    var features: Set<String>

    static func fetch(serial: String) throws -> DeviceProps {
        let featureList = try ADBSocket.query("host-serial:\(serial):features", timeout: 10)
        let features = Set(featureList.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let link = Link(serial: serial, features: features)
        let script = "getprop ro.serialno; getprop ro.product.manufacturer; getprop ro.product.model; "
                   + "getprop ro.build.version.release; settings get global device_name 2>/dev/null"
        let lines = try Shell.run(link, script, timeout: 15).stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func line(_ index: Int) -> String { index < lines.count ? lines[index] : "" }

        let hardware = line(0)
        var name = line(4)
        if name.isEmpty || name == "null" {
            let maker = line(1).prefix(1).uppercased() + line(1).dropFirst()
            name = [maker, line(2)].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if name.isEmpty { name = serial }
        return DeviceProps(hardwareSerial: hardware.isEmpty ? serial : hardware,
                           name: name, android: line(3), features: features)
    }
}

/// A physical tablet with every transport that currently reaches it.
struct Tablet: Identifiable, Equatable {
    var id: String                    // hardware serial (ro.serialno) when known
    var name: String
    var android: String = ""
    var transports: [Transport] = []
    var features: [String: Set<String>] = [:]     // per transport serial; present = ready to use

    private func link(_ transport: Transport?) -> Link? {
        guard let transport, let features = features[transport.serial] else { return nil }
        return Link(serial: transport.serial, features: features)
    }

    var usbTransport: Transport? {
        transports.first { $0.kind != .wifi && $0.isReady && features[$0.serial] != nil }
    }
    var wifiTransport: Transport? {
        transports.first { $0.kind == .wifi && $0.isReady && features[$0.serial] != nil }
    }

    var usbLink: Link? { link(usbTransport) }
    var wifiLink: Link? { link(wifiTransport) }

    /// Cable first — it is several times faster than Wi-Fi.
    var link: Link? { usbLink ?? wifiLink }
    var isReady: Bool { link != nil }
    var isEmulator: Bool { transports.contains { $0.kind == .emulator } }

    var isUnauthorized: Bool {
        !isReady && transports.contains { $0.state == "unauthorized" || $0.state == "authorizing" }
    }

    var isConnecting: Bool {
        !isReady && transports.contains { $0.isReady || $0.state == "connecting" }
    }

    /// "192.168.1.42" for a Wi-Fi connection, when there is one.
    var wifiAddress: String? {
        guard let serial = wifiTransport?.serial, serial.contains(":"), !serial.contains("._adb") else { return nil }
        return String(serial[..<serial.lastIndex(of: ":")!])
    }

    var subtitle: String {
        if isUnauthorized { return "Разрешите доступ на планшете" }
        if isConnecting { return "Подключаюсь…" }
        if !isReady { return "Не отвечает" }
        var parts: [String] = []
        if !android.isEmpty { parts.append("Android \(android)") }
        switch (usbTransport != nil, wifiTransport != nil) {
        case (true, true):  parts.append(isEmulator ? "эмулятор и Wi-Fi" : "кабель и Wi-Fi")
        case (true, false): parts.append(isEmulator ? "эмулятор" : "кабель")
        case (false, true): parts.append("Wi-Fi")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

/// Services found by the adb server's own mDNS browser.
struct MDNSService: Hashable {
    var name: String
    var type: String
    var address: String               // "ip:port"
}

enum MDNS {
    static func services() throws -> [MDNSService] {
        let text = try ADBSocket.query("host:mdns:services", timeout: 5)
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            return MDNSService(name: parts[0], type: parts[1], address: parts[2])
        }
    }
}
