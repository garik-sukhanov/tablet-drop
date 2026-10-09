import SwiftUI
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    let hub: DeviceHub

    @Published var selection: String?
    @Published var showWiFi = false

    private var sessions: [String: Session] = [:]
    private var subscriptions = Set<AnyCancellable>()

    init(hub: DeviceHub) {
        self.hub = hub
        hub.$tablets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tablets in self?.tabletsChanged(tablets) }
            .store(in: &subscriptions)
    }

    var selectedTablet: Tablet? {
        hub.tablets.first { $0.id == selection }
    }

    var currentSession: Session? {
        guard let tablet = selectedTablet, tablet.isReady else { return nil }
        return session(for: tablet.id)
    }

    func session(for id: String) -> Session {
        if let existing = sessions[id] { return existing }
        let session = Session(tabletID: id, hub: hub)
        sessions[id] = session
        return session
    }

    private func tabletsChanged(_ tablets: [Tablet]) {
        if selection == nil || !tablets.contains(where: { $0.id == selection }) {
            selection = (tablets.first(where: \.isReady) ?? tablets.first)?.id
        }
        for tablet in tablets where tablet.isReady {
            sessions[tablet.id]?.deviceReady()
        }
        objectWillChange.send()               // menu items depend on the tablet list
    }

    func chooseFilesForUpload() {
        guard let session = currentSession else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "На планшет"
        panel.message = "Файлы и папки скопируются в «\(session.folderTitle)»"
        if panel.runModal() == .OK {
            session.upload(panel.urls, to: session.path)
        }
    }
}
