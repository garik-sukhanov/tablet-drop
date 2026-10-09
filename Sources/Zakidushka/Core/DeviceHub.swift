import Foundation

/// Keeps a `host:track-devices-l` stream open and reports every change.
/// Restarts the adb server and reconnects if anything goes wrong.
final class DeviceTracker {
    var onDevices: (([Transport]) -> Void)?
    var onStatus: ((DeviceHub.Status) -> Void)?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "adb-device-tracker"
        thread.start()
    }

    private func loop() {
        while true {
            do {
                try ADBTool.ensureServer()
                let socket = try ADBSocket()
                defer { socket.close() }
                try socket.open("host:track-devices-l")
                onStatus?(.running)
                while true {
                    onDevices?(Transport.parse(try socket.readString()))
                }
            } catch ADBError.adbMissing {
                onDevices?([])
                onStatus?(.adbMissing)
                Thread.sleep(forTimeInterval: 3)
            } catch {
                onDevices?([])
                onStatus?(.failed(error.localizedDescription))
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }
}

/// Tablets switched to Wi-Fi with "adb tcpip": hardware serial → "ip:5555".
/// Lets the app reconnect them on its own after a restart.
final class WiFiMemory {
    private let key = "wifiHosts"

    var hosts: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    func remember(_ host: String, for serial: String) { hosts[serial] = host }
    func forget(_ serial: String) { hosts[serial] = nil }
    func serial(forHost host: String) -> String? { hosts.first { $0.value == host }?.key }
}

/// The list of tablets, merged from adb transports (one tablet may be on the
/// cable and on Wi-Fi at the same time).
@MainActor
final class DeviceHub: ObservableObject {
    enum Status: Equatable {
        case starting, running, adbMissing
        case failed(String)
    }

    @Published private(set) var tablets: [Tablet] = []
    @Published private(set) var status: Status = .starting

    let wifiMemory = WiFiMemory()

    private let tracker = DeviceTracker()
    private var transports: [Transport] = []
    private var props: [String: DeviceProps] = [:]          // by transport serial
    private var loadingProps: Set<String> = []
    private var started = false
    private var timer: Timer?

    private var reconnecting = false
    private var failures: [String: Int] = [:]
    private var nextAttempt: [String: Date] = [:]
    private let wifiQueue = DispatchQueue(label: "me.garik.Zakidushka.wifi", qos: .utility)

    func start() {
        guard !started else { return }
        started = true
        tracker.onDevices = { [weak self] list in
            DispatchQueue.main.async { self?.apply(list) }
        }
        tracker.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.status != status else { return }
                self.status = status
            }
        }
        tracker.start()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconnectRemembered() }
        }
    }

    func link(for id: String) -> Link? {
        tablets.first { $0.id == id }?.link
    }

    // MARK: - Tracking

    private func apply(_ list: [Transport]) {
        transports = list
        let alive = Set(list.map(\.serial))
        props = props.filter { alive.contains($0.key) }

        for transport in list where transport.isReady
            && props[transport.serial] == nil && !loadingProps.contains(transport.serial) {
            loadProps(transport.serial)
        }
        rebuild()
    }

    private func loadProps(_ serial: String) {
        loadingProps.insert(serial)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try DeviceProps.fetch(serial: serial) }
            DispatchQueue.main.async {
                self.loadingProps.remove(serial)
                switch result {
                case .success(let value):
                    self.props[serial] = value
                    self.rebuild()
                case .failure:
                    // The tablet may still be waking up; try again shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.apply(self.transports) }
                }
            }
        }
    }

    private func rebuild() {
        var groups: [String: Tablet] = [:]
        var order: [String] = []

        for var transport in transports {
            let info = props[transport.serial]
            if transport.isReady && info == nil { transport.state = "connecting" }

            let key = info?.hardwareSerial
                ?? wifiMemory.serial(forHost: transport.serial)
                ?? transport.serialFromServiceName
                ?? transport.serial

            if groups[key] == nil {
                let fallback = transport.info["model"]?.replacingOccurrences(of: "_", with: " ")
                groups[key] = Tablet(id: key, name: fallback ?? "Android-устройство")
                order.append(key)
            }
            groups[key]!.transports.append(transport)
            if let info {
                groups[key]!.name = info.name
                groups[key]!.android = info.android
                groups[key]!.features[transport.serial] = info.features
            }
        }

        let list = order.compactMap { groups[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if list != tablets { tablets = list }
    }

    // MARK: - Wi-Fi

    /// Switches a cable-connected tablet to Wi-Fi ("adb tcpip 5555") and
    /// connects to it. Works until the tablet reboots.
    func enableWiFi(_ tablet: Tablet) async throws -> String {
        guard let usb = tablet.usbLink else {
            throw ADBError.device("Сначала подключите планшет кабелем")
        }
        let host = try await Task.detached(priority: .userInitiated) {
            try WiFiSetup.switchToTCP(usb)
        }.value
        wifiMemory.remember(host, for: tablet.id)
        failures[host] = nil
        nextAttempt[host] = nil
        return host
    }

    /// Turns "adb tcpip" mode off on the tablet and stops reconnecting to it.
    func disableWiFi(_ tablet: Tablet) async {
        let remembered = wifiMemory.hosts[tablet.id]
        wifiMemory.forget(tablet.id)
        let link = tablet.link
        let tcpMode = tablet.wifiTransport?.isTCPMode ?? (remembered != nil)
        let wifiSerials = tablet.transports.filter { $0.kind == .wifi }.map(\.serial)
        await Task.detached(priority: .userInitiated) {
            if tcpMode, let link {
                // Restarts adbd listening on USB only.
                if let socket = try? ADBSocket.device(link.serial, service: "usb:", timeout: 10) {
                    _ = try? socket.readToEnd()
                    socket.close()
                }
            }
            for serial in Set(wifiSerials + [remembered].compactMap { $0 }) {
                _ = try? ADBSocket.query("host:disconnect:\(serial)", timeout: 5)
            }
        }.value
    }

    /// Quietly reconnects tablets that were switched to Wi-Fi earlier.
    /// Backs off when a tablet keeps refusing (it rebooted or is not around).
    private func reconnectRemembered() {
        guard status == .running, !reconnecting else { return }
        let present = Set(transports.map(\.serial))
        let now = Date()
        let due = Array(Set(wifiMemory.hosts.values)).filter {
            !present.contains($0) && (nextAttempt[$0] ?? .distantPast) <= now
        }
        guard !due.isEmpty else { return }
        reconnecting = true
        wifiQueue.async {
            var results: [String: Bool] = [:]
            for host in due {
                let reply = (try? ADBSocket.query("host:connect:\(host)", timeout: 12)) ?? ""
                results[host] = reply.contains("connected to")
            }
            DispatchQueue.main.async {
                self.reconnecting = false
                for (host, ok) in results {
                    if ok {
                        self.failures[host] = nil
                        self.nextAttempt[host] = nil
                    } else {
                        let count = (self.failures[host] ?? 0) + 1
                        self.failures[host] = count
                        let delay = min(120, 5 * pow(2, Double(min(count, 5))))
                        self.nextAttempt[host] = Date().addingTimeInterval(delay)
                    }
                }
            }
        }
    }
}

/// Blocking Wi-Fi helpers — call them off the main thread.
enum WiFiSetup {
    static func switchToTCP(_ link: Link) throws -> String {
        let addresses = try Shell.run(link, "ip -4 -o addr show", timeout: 10).stdout
        guard let ip = wifiAddress(in: addresses) else {
            throw ADBError.device("Планшет не подключён к Wi-Fi. Подключите его к той же сети, что и Mac")
        }

        let socket = try ADBSocket.device(link.serial, service: "tcpip:5555", timeout: 10)
        _ = try? socket.readToEnd()                    // "restarting in TCP mode port: 5555"
        socket.close()

        let host = "\(ip):5555"
        var reply = ""
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 1)
            reply = (try? ADBSocket.query("host:connect:\(host)", timeout: 8)) ?? reply
            if reply.contains("connected to") { return host }
        }
        throw ADBError.device(reply.isEmpty
            ? "Не удалось подключиться к \(host). Mac и планшет в одной сети Wi-Fi?"
            : ADBError.humanize(reply))
    }

    /// Picks the Wi-Fi address out of `ip -4 -o addr show`.
    static func wifiAddress(in text: String) -> String? {
        var fallback: String?
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: #"inet \d+\.\d+\.\d+\.\d+"#, options: .regularExpression) else { continue }
            let ip = String(line[range].dropFirst(5))
            if ip.hasPrefix("127.") { continue }
            if line.contains("wlan") { return ip }
            if fallback == nil, line.contains("eth") { fallback = ip }
        }
        return fallback
    }

    /// Wireless-debugging pairing (Android 11+) through the adb server, then
    /// a connection to the freshly paired tablet. Returns the address it
    /// connected to, or nil when the tablet will be picked up automatically.
    static func pair(address: String, code: String, stop: StopFlag? = nil) throws -> String? {
        let reply = try ADBSocket.query("host:pair:\(code):\(address)", timeout: 45)
        guard reply.lowercased().contains("successfully paired") else {
            throw ADBError.device(humanizePairing(reply))
        }
        var guid: String?
        if let range = reply.range(of: #"guid=[^\]\s]+"#, options: .regularExpression) {
            guid = String(reply[range].dropFirst(5))
        }
        let ip = address.split(separator: ":").first.map(String.init) ?? address

        // The tablet announces its connect port over mDNS a moment later.
        for _ in 0..<15 {
            if stop?.isSet == true { return nil }
            let match = ((try? MDNS.services()) ?? []).first { service in
                guard service.type.contains("_adb-tls-connect") else { return false }
                if let guid { return service.name == guid }
                return service.address.hasPrefix(ip + ":")
            }
            if let match {
                let result = (try? ADBSocket.query("host:connect:\(match.address)", timeout: 10)) ?? ""
                if result.contains("connected to") { return match.address }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    static func humanizePairing(_ reply: String) -> String {
        let lower = reply.lowercased()
        if lower.contains("wrong password") || lower.contains("password") {
            return "Не подошёл код — проверьте цифры и попробуйте ещё раз"
        }
        if lower.contains("unable to start pairing") || lower.contains("connection refused") {
            return "Планшет не отвечает по этому адресу. Окно с кодом на планшете ещё открыто?"
        }
        return ADBError.humanize(reply)
    }
}

/// A thread-safe "please stop" switch for background loops.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}
