import XCTest
@testable import Zakidushka

/// End-to-end tests against a real tablet or an emulator. They are skipped
/// when nothing is connected. Pick a device with ZAKIDUSHKA_SERIAL=…
/// Everything is written to /data/local/tmp — never to the user's storage.
final class LiveDeviceTests: XCTestCase {
    private var link: Link!
    private var remoteDir = ""
    private var localDir: URL!

    override func setUpWithError() throws {
        do {
            try ADBTool.ensureServer()
        } catch {
            throw XCTSkip("adb недоступен: \(error.localizedDescription)")
        }
        let devices = Transport.parse(try ADBSocket.query("host:devices-l")).filter(\.isReady)
        let wanted = ProcessInfo.processInfo.environment["ZAKIDUSHKA_SERIAL"]
        guard let device = devices.first(where: { wanted == nil || $0.serial == wanted }) else {
            throw XCTSkip("Нет подключённого планшета или эмулятора")
        }
        let props = try DeviceProps.fetch(serial: device.serial)
        link = Link(serial: device.serial, features: props.features)
        remoteDir = "/data/local/tmp/zakidushka-tests-\(UUID().uuidString.prefix(8))"
        localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zakidushka-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let link, !remoteDir.isEmpty {
            _ = try? Shell.run(link, "rm -rf -- \(Shell.quote(remoteDir))")
        }
        if let localDir { try? FileManager.default.removeItem(at: localDir) }
    }

    private func randomFile(_ name: String, size: Int) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in stride(from: 0, to: size, by: 4096) { bytes[i] = UInt8.random(in: 0...255) }
        for i in 0..<min(size, 1000) { bytes[i] = UInt8.random(in: 0...255) }
        let url = localDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Protocol level

    func testDeviceAdvertisesModernFeatures() {
        XCTAssertTrue(link.features.contains("shell_v2"))
        XCTAssertTrue(link.features.contains("ls_v2"))
    }

    func testShellExitCodesAndQuoting() throws {
        let result = try Shell.run(link, "echo out; echo err >&2; exit 3")
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")

        let nasty = "a'b \"c\" $HOME `id` ; & | * Ёлка"
        XCTAssertEqual(try Shell.check(link, "printf %s \(Shell.quote(nasty))"), nasty)

        XCTAssertThrowsError(try Shell.check(link, "ls /definitely/not/here"))
    }

    func testListInternalStorage() throws {
        let sync = try SyncSession(link: link)
        defer { sync.close() }
        let files = try Session.list(sync, StorageRoot.internalPath)
        XCTAssertTrue(files.contains { $0.name == "Download" && $0.isDirectory })
        XCTAssertNil(try sync.stat("/storage/emulated/0/no-such-folder-\(UUID().uuidString)"))
    }

    func testPushPullRoundTrip() throws {
        let name = "Тест файл 'кавычки' #1.bin"
        let local = try randomFile(name, size: 5 * 1024 * 1024 + 123)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: local.path)

        let remote = remoteDir + "/папка с пробелом/" + name     // parents do not exist yet
        let sync = try SyncSession(link: link)
        defer { sync.close() }

        var lastProgress: Int64 = 0
        try sync.push(local, to: remote) { lastProgress = $0; return true }
        XCTAssertEqual(lastProgress, 5 * 1024 * 1024 + 123)

        let info = try XCTUnwrap(try sync.stat(remote))
        XCTAssertEqual(info.size, 5 * 1024 * 1024 + 123)
        XCTAssertEqual(info.mtime, mtime)

        let listed = try Session.list(sync, remoteDir + "/папка с пробелом")
        XCTAssertEqual(listed.map(\.name), [name])

        let back = localDir.appendingPathComponent("back.bin")
        try sync.pull(remote, to: back, mtime: info.mtime) { _ in true }
        XCTAssertEqual(try Data(contentsOf: back), try Data(contentsOf: local))
        let backDate = try FileManager.default.attributesOfItem(atPath: back.path)[.modificationDate] as? Date
        XCTAssertEqual(backDate, mtime)
    }

    func testCancelledPushLeavesNothingBehind() throws {
        let local = try randomFile("big.bin", size: 24 * 1024 * 1024)
        let remote = remoteDir + "/big.bin"
        let sync = try SyncSession(link: link)
        XCTAssertThrowsError(try sync.push(local, to: remote) { $0 < 2 * 1024 * 1024 }) { error in
            XCTAssertEqual(error as? ADBError, .cancelled)
        }
        sync.close()

        // adbd removes the partial file once the connection drops.
        let check = try SyncSession(link: link)
        defer { check.close() }
        var gone = false
        for _ in 0..<20 {
            if try check.stat(remote) == nil { gone = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(gone, "частичный файл остался на устройстве")
    }

    func testPullOfMissingFileFails() throws {
        let sync = try SyncSession(link: link)
        defer { sync.close() }
        let target = localDir.appendingPathComponent("nothing.bin")
        XCTAssertThrowsError(try sync.pull(remoteDir + "/nothing.bin", to: target, mtime: nil) { _ in true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - Whole app stack: hub → session → queue

    @MainActor
    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    @MainActor
    func testHubSessionUploadConflictDownloadDelete() async throws {
        let serial = link.serial
        let hub = DeviceHub()
        hub.start()
        let found = await waitUntil(20) { hub.tablets.contains { $0.link?.serial == serial } }
        XCTAssertTrue(found, "DeviceHub не увидел устройство")
        let tablet = try XCTUnwrap(hub.tablets.first { $0.link?.serial == serial })

        let session = Session(tabletID: tablet.id, hub: hub)
        session.start()
        let opened = await waitUntil(15) { session.state == .ready && session.space != nil }
        XCTAssertTrue(opened)
        XCTAssertEqual(session.path, StorageRoot.internalPath)
        XCTAssertTrue(session.files.contains { $0.name == "Download" })

        // A folder with a nested file, an empty subfolder and Finder junk.
        let folder = localDir.appendingPathComponent("Фото с дачи")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Пустая"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Вечер"), withIntermediateDirectories: true)
        _ = try randomFile("Фото с дачи/1.jpg", size: 300_000)
        _ = try randomFile("Фото с дачи/Вечер/2.jpg", size: 700_000)
        try Data(count: 6).write(to: folder.appendingPathComponent(".DS_Store"))
        let film = try randomFile("фильм.mp4", size: 3_000_000)

        session.upload([folder, film], to: remoteDir)
        let uploaded = await waitUntil(60) {
            session.transfers.count == 3 && session.transfers.allSatisfy { $0.state == .done }
        }
        XCTAssertTrue(uploaded, "загрузка не завершилась: \(session.transfers.map(\.state))")

        let sync = try SyncSession(link: link)
        defer { sync.close() }
        XCTAssertEqual(try sync.stat(remoteDir + "/Фото с дачи/Вечер/2.jpg")?.size, 700_000)
        XCTAssertEqual(try sync.stat(remoteDir + "/фильм.mp4")?.size, 3_000_000)
        XCTAssertTrue(try sync.stat(remoteDir + "/Фото с дачи/Пустая")?.isDirectory ?? false)
        XCTAssertNil(try sync.stat(remoteDir + "/Фото с дачи/.DS_Store"))

        // The same drop again → the app asks before overwriting.
        session.upload([film], to: remoteDir)
        let asked = await waitUntil(10) { session.conflict != nil }
        XCTAssertTrue(asked)
        XCTAssertEqual(session.conflict?.names, ["фильм.mp4"])
        session.resolve(try XCTUnwrap(session.conflict), replace: true)
        let replaced = await waitUntil(30) { session.transfers.count == 4 && session.transfers.allSatisfy { $0.state == .done } }
        XCTAssertTrue(replaced)

        // Download the folder back and compare.
        session.navigate(to: remoteDir)
        let listed = await waitUntil(10) { session.path == remoteDir && session.files.count == 2 }
        XCTAssertTrue(listed)
        let downloads = localDir.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        session.download(session.files.filter(\.isDirectory), to: downloads)
        let downloaded = await waitUntil(30) {
            session.transfers.count == 6 && session.transfers.allSatisfy { $0.state == .done }
        }
        XCTAssertTrue(downloaded, "скачивание не завершилось: \(session.transfers.map(\.state))")
        XCTAssertEqual(try Data(contentsOf: downloads.appendingPathComponent("Фото с дачи/Вечер/2.jpg")),
                       try Data(contentsOf: folder.appendingPathComponent("Вечер/2.jpg")))

        // Delete everything through the session.
        session.delete(session.files)
        let emptied = await waitUntil(10) { session.files.isEmpty && !session.loading }
        XCTAssertTrue(emptied)
        session.close()
    }
}
