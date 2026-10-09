import SwiftUI

struct ContentView: View {
    @EnvironmentObject var hub: DeviceHub
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .sheet(isPresented: $app.showWiFi) {
            WiFiSheet()
                .environmentObject(hub)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if hub.status == .adbMissing {
            ADBMissingView()
        } else if let tablet = app.selectedTablet {
            if tablet.isReady {
                BrowserView(session: app.session(for: tablet.id), tablet: tablet)
                    .id(tablet.id)
            } else {
                PendingTabletView(tablet: tablet)
            }
        } else if case .failed(let message) = hub.status {
            ServerProblemView(message: message)
        } else if hub.status == .starting {
            VStack(spacing: 10) {
                ProgressView()
                Text("Запускаю adb…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NoTabletView()
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var hub: DeviceHub
    @EnvironmentObject var app: AppState
    @State private var wifiError: String?

    var body: some View {
        List(selection: $app.selection) {
            Section("Планшеты") {
                if hub.tablets.isEmpty {
                    Text(hub.status == .running ? "Пока никого" : "—")
                        .foregroundStyle(.tertiary)
                }
                ForEach(hub.tablets) { tablet in
                    TabletRow(tablet: tablet)
                        .tag(tablet.id)
                        .contextMenu { menu(for: tablet) }
                }
            }
            if let tablet = app.selectedTablet, tablet.isReady {
                PlacesSection(session: app.session(for: tablet.id))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { app.showWiFi = true } label: {
                    Label("Wi-Fi", systemImage: "wifi")
                }
                .buttonStyle(.accessoryBar)
                .help("Подключить планшет по Wi-Fi (⌘K)")
                Spacer()
            }
            .padding(8)
        }
        .alert("Wi-Fi", isPresented: Binding(get: { wifiError != nil }, set: { if !$0 { wifiError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(wifiError ?? "")
        }
    }

    @ViewBuilder
    private func menu(for tablet: Tablet) -> some View {
        if tablet.usbLink != nil, tablet.wifiLink == nil, !tablet.isEmulator {
            Button("Включить Wi-Fi") {
                Task {
                    do { _ = try await hub.enableWiFi(tablet) } catch { wifiError = error.localizedDescription }
                }
            }
        }
        if tablet.wifiTransport?.isTCPMode == true || hub.wifiMemory.hosts[tablet.id] != nil {
            Button("Выключить Wi-Fi") {
                Task { await hub.disableWiFi(tablet) }
            }
        }
        Button("Подключение по Wi-Fi…") { app.showWiFi = true }
    }
}

struct TabletRow: View {
    let tablet: Tablet

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ipad.landscape")
                .foregroundStyle(tablet.isReady ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(tablet.name).lineLimit(1)
                Text(tablet.subtitle)
                    .font(.caption)
                    .foregroundStyle(tablet.isUnauthorized ? Color.orange : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if tablet.usbLink != nil, !tablet.isEmulator {
                Image(systemName: "cable.connector")
                    .foregroundStyle(.secondary)
                    .help("Подключён кабелем")
            }
            if tablet.wifiLink != nil {
                Image(systemName: "wifi")
                    .foregroundStyle(.secondary)
                    .help(tablet.wifiAddress.map { "По Wi-Fi: \($0)" } ?? "По Wi-Fi")
            }
        }
        .padding(.vertical, 2)
    }
}

struct PlacesSection: View {
    @ObservedObject var session: Session

    var body: some View {
        Section("Места") {
            ForEach(session.places) { place in
                PlaceRow(place: place, isCurrent: session.path == place.path) {
                    session.navigate(to: place.path)
                } onDrop: { urls in
                    session.upload(urls, to: place.path)
                }
            }
        }
    }
}

struct PlaceRow: View {
    let place: Place
    let isCurrent: Bool
    let open: () -> Void
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: open) {
            Label {
                Text(place.title).fontWeight(isCurrent ? .semibold : .regular)
            } icon: {
                Image(systemName: place.icon)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(targeted ? Color.accentColor.opacity(0.25) : .clear))
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { targeted = $0 }
        .help("Перетащите сюда файлы — они скопируются в «\(place.title)»")
    }
}

// MARK: - Empty and waiting states

struct NoTabletView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "ipad.landscape")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("Подключите планшет")
                    .font(.title2)
                Text("Кабелем USB — или по Wi-Fi")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Первый раз на планшете нужно включить отладку:").bold()
                    Step(n: 1, text: "Настройки → Сведения о планшете → Сведения о ПО → семь раз нажмите «Номер сборки».")
                    Step(n: 2, text: "Настройки → Параметры разработчика → включите «Отладка по USB».")
                    Step(n: 3, text: "Подключите кабель. На планшете появится «Разрешить отладку по USB?» — отметьте «Всегда разрешать с этого компьютера» и нажмите «Разрешить».")
                }
                .padding(16)
                .frame(maxWidth: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

                Button("Подключить по Wi-Fi…") { app.showWiFi = true }
                    .controlSize(.large)
            }
            .padding(30)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct Step: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PendingTabletView: View {
    let tablet: Tablet

    var body: some View {
        VStack(spacing: 14) {
            if tablet.isUnauthorized {
                Image(systemName: "hand.raised")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.orange)
                Text("Посмотрите на экран планшета").font(.title2)
                Text("Там окно «Разрешить отладку по USB?». Отметьте «Всегда разрешать с этого компьютера» и нажмите «Разрешить».")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                Text("Окна нет? Отключите и снова подключите кабель.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if tablet.isConnecting {
                ProgressView()
                Text("Подключаюсь к «\(tablet.name)»…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.orange)
                Text("Планшет не отвечает").font(.title2)
                Text("Переподключите кабель или проверьте Wi-Fi.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ServerProblemView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.orange)
            Text("Не получается запустить adb").font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)
            Text("Пробую снова каждые пару секунд.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ADBMissingView: View {
    @State private var downloading = false
    @State private var progress = 0.0
    @State private var error: String?
    @State private var installed = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 50, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Нужен adb").font(.title2)
            Text("Это небольшая утилита Google (Android Platform Tools), через которую Mac разговаривает с планшетом. Приложение скачает её с сайта Google — около 15 МБ.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if downloading {
                ProgressView(value: progress).frame(width: 260)
            } else if installed {
                Label("Установлено, подключаюсь…", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Скачать adb") { download() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            Text("Или в Терминале: brew install --cask android-platform-tools")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func download() {
        downloading = true
        error = nil
        Task {
            do {
                try await PlatformTools.install { value in
                    Task { @MainActor in progress = value }
                }
                installed = true
            } catch {
                self.error = error.localizedDescription
            }
            downloading = false
        }
    }
}
