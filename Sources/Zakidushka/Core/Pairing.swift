import Foundation

/// Wireless-debugging pairing (Android 11+): by QR code or by the six-digit
/// code the tablet shows.
///
/// QR flow, as in Android Studio: we show `WIFI:T:ADB;S:<name>;P:<password>;;`,
/// the tablet scans it and starts announcing a `_adb-tls-pairing._tcp`
/// service called <name>; we spot it through the adb server's mDNS and pair.
@MainActor
final class Pairing: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waiting                  // QR is on screen, the tablet has not scanned it yet
        case pairing
        case done(String?)            // connected address, nil = will connect by itself
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    let serviceName = "zakidushka-" + Pairing.random(6, from: "abcdefghijkmnpqrstuvwxyz23456789")
    let password = Pairing.random(10, from: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    var qrPayload: String { "WIFI:T:ADB;S:\(serviceName);P:\(password);;" }

    private var stop = StopFlag()

    var isBusy: Bool { phase == .waiting || phase == .pairing }

    func startQR() {
        guard !isBusy else { return }
        stop = StopFlag()
        phase = .waiting
        let name = serviceName, password = self.password, stop = self.stop
        DispatchQueue.global(qos: .userInitiated).async {
            while !stop.isSet {
                let match = (try? MDNS.services())?.first {
                    $0.name == name && $0.type.contains("_adb-tls-pairing")
                }
                if let match {
                    DispatchQueue.main.async { if !stop.isSet { self.phase = .pairing } }
                    let result = Result { try WiFiSetup.pair(address: match.address, code: password, stop: stop) }
                    DispatchQueue.main.async { if !stop.isSet { self.finish(result) } }
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    func pair(address: String, code: String) {
        guard !isBusy else { return }
        stop = StopFlag()
        phase = .pairing
        let stop = self.stop
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try WiFiSetup.pair(address: address, code: code, stop: stop) }
            DispatchQueue.main.async { if !stop.isSet { self.finish(result) } }
        }
    }

    func cancel() {
        stop.set()
        if isBusy { phase = .idle }
    }

    func reset() {
        cancel()
        phase = .idle
    }

    private func finish(_ result: Result<String?, Error>) {
        switch result {
        case .success(let address): phase = .done(address)
        case .failure(let error):   phase = .failed(error.localizedDescription)
        }
    }

    private static func random(_ count: Int, from alphabet: String) -> String {
        let chars = Array(alphabet)
        return String((0..<count).map { _ in chars.randomElement()! })
    }
}
