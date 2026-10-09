import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .background).async { DragProvider.cleanUpOldStaging() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ZakidushkaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var hub: DeviceHub
    @StateObject private var app: AppState
    @AppStorage("showHidden") private var showHidden = false

    init() {
        let hub = DeviceHub()
        _hub = StateObject(wrappedValue: hub)
        _app = StateObject(wrappedValue: AppState(hub: hub))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(hub)
                .environmentObject(app)
                .frame(minWidth: 860, minHeight: 540)
                .onAppear { hub.start() }
        }
        .defaultSize(width: 1080, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая папка") { app.currentSession?.newFolderRequested = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(app.currentSession == nil)
                Button("Загрузить на планшет…") { app.chooseFilesForUpload() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(app.currentSession == nil)
                Divider()
                Button("Подключение по Wi-Fi…") { app.showWiFi = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Обновить") { app.currentSession?.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(app.currentSession == nil)
                Button("Наверх") { app.currentSession?.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(app.currentSession == nil)
                Toggle("Показывать скрытые файлы", isOn: $showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}
