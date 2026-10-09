import SwiftUI
import CoreImage.CIFilterBuiltins

/// Three ways to get a tablet onto Wi-Fi: one click while it is on the cable,
/// a QR code, or the pairing code (the last two need Android 11+).
struct WiFiSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case cable = "Через кабель"
        case qr = "QR-код"
        case code = "Код"
        var id: Self { self }
    }

    @EnvironmentObject var hub: DeviceHub
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = Pairing()

    @State private var mode: Mode = .cable
    @State private var busyTablet: String?
    @State private var enabledHost: String?
    @State private var cableError: String?
    @State private var address = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Подключение по Wi-Fi").font(.title3.bold())
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .cable: cablePane
                case .qr:    qrPane
                case .code:  codePane
                }
            }
            .frame(minHeight: 250, alignment: .top)

            Divider()
            HStack(alignment: .top) {
                Text("Mac и планшет должны быть в одной сети Wi-Fi. По проводу копирование быстрее раза в два-три.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if !hub.tablets.contains(where: { $0.usbLink != nil && !$0.isEmulator }) { mode = .qr }
            if mode == .qr { pairing.startQR() }
        }
        .onChange(of: mode) {
            if mode == .qr { pairing.startQR() } else if pairing.phase == .waiting { pairing.cancel() }
        }
        .onDisappear { pairing.cancel() }
    }

    // MARK: - Cable

    private var cablePane: some View {
        let onCable = hub.tablets.filter { $0.usbLink != nil && !$0.isEmulator }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Подключите планшет кабелем и нажмите «Включить Wi-Fi». Дальше кабель можно убрать — Wi-Fi работает до перезагрузки планшета, а Закидушка потом подключается к нему сама.")
                .fixedSize(horizontal: false, vertical: true)

            if onCable.isEmpty {
                Label("Сейчас ни один планшет не подключён кабелем", systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            ForEach(onCable) { tablet in
                HStack(spacing: 10) {
                    Image(systemName: "ipad.landscape")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tablet.name)
                        Text(tablet.wifiAddress.map { "По Wi-Fi: \($0)" } ?? "Только кабель")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if tablet.wifiLink != nil {
                        Label("Wi-Fi включён", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if busyTablet == tablet.id {
                        ProgressView().controlSize(.small)
                        Text("Переключаю…").foregroundStyle(.secondary)
                    } else {
                        Button("Включить Wi-Fi") { enable(tablet) }
                            .disabled(busyTablet != nil)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }

            if let enabledHost {
                Label("Готово: планшет доступен по адресу \(enabledHost). Кабель можно отключить.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let cableError {
                Label(cableError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func enable(_ tablet: Tablet) {
        busyTablet = tablet.id
        cableError = nil
        enabledHost = nil
        Task {
            do {
                let host = try await hub.enableWiFi(tablet)
                enabledHost = host.replacingOccurrences(of: ":5555", with: "")
            } catch {
                cableError = error.localizedDescription
            }
            busyTablet = nil
        }
    }

    // MARK: - QR

    private var qrPane: some View {
        HStack(alignment: .top, spacing: 18) {
            QRCodeView(text: pairing.qrPayload)
                .frame(width: 190, height: 190)
            VStack(alignment: .leading, spacing: 8) {
                Text("Без кабеля (Android 11 и новее):").bold()
                Text("1. На планшете: Настройки → Параметры разработчика → включите «Отладка по Wi-Fi».")
                Text("2. Нажмите на сами слова «Отладка по Wi-Fi», затем «Подключить устройство с помощью QR-кода».")
                Text("3. Наведите камеру планшета на этот код.")
                pairingStatus
                    .padding(.top, 4)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Code

    private var codePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Если камера не видит код: «Отладка по Wi-Fi» → «Подключить устройство с помощью кода подключения». Введите то, что покажет планшет:")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("IP-адрес и порт, например 192.168.1.5:37099", text: $address)
                    .textFieldStyle(.roundedBorder)
                TextField("Код", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            Button("Подключить") {
                pairing.pair(address: address.trimmingCharacters(in: .whitespaces),
                             code: code.trimmingCharacters(in: .whitespaces))
            }
            .disabled(!address.contains(":") || code.trimmingCharacters(in: .whitespaces).count < 6 || pairing.isBusy)
            pairingStatus
        }
    }

    @ViewBuilder
    private var pairingStatus: some View {
        switch pairing.phase {
        case .idle:
            EmptyView()
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Жду, когда планшет отсканирует код…").foregroundStyle(.secondary)
            }
        case .pairing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Подключаю…").foregroundStyle(.secondary)
            }
        case .done(let address):
            Label(address == nil
                  ? "Сопряжено. Планшет подключится сам, как только включена «Отладка по Wi-Fi»."
                  : "Готово! Планшет подключён по Wi-Fi.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Ещё раз") {
                    pairing.reset()
                    if mode == .qr { pairing.startQR() }
                }
            }
        }
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = QRCode.image(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1))
        }
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
