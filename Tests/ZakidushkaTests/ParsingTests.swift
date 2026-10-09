import XCTest
@testable import Zakidushka

/// Pure logic — no tablet needed.
final class ParsingTests: XCTestCase {
    func testDeviceListParsing() {
        let text = """
        R58M90ABCDE            device usb:1-1 product:gtact4prowifixx model:SM_T630 device:gtact4prowifi transport_id:1
        192.168.1.42:5555     device product:gtact4prowifixx model:SM_T630 device:gtact4prowifi transport_id:4
        adb-R58M90ABCDE-AbCdEf._adb-tls-connect._tcp device product:gtact4prowifixx model:SM_T630 transport_id:5
        0123456789ABCDEF       unauthorized usb:1-2 transport_id:6
        emulator-5554          device product:sdk_gtablet_arm64 model:Pixel_Tablet device:emu64a transport_id:7

        """
        let list = Transport.parse(text)
        XCTAssertEqual(list.count, 5)

        XCTAssertEqual(list[0].serial, "R58M90ABCDE")
        XCTAssertEqual(list[0].kind, .usb)
        XCTAssertTrue(list[0].isReady)
        XCTAssertEqual(list[0].info["model"], "SM_T630")

        XCTAssertEqual(list[1].kind, .wifi)
        XCTAssertTrue(list[1].isTCPMode)

        XCTAssertEqual(list[2].kind, .wifi)
        XCTAssertFalse(list[2].isTCPMode)
        XCTAssertEqual(list[2].serialFromServiceName, "R58M90ABCDE")

        XCTAssertEqual(list[3].state, "unauthorized")
        XCTAssertFalse(list[3].isReady)

        XCTAssertEqual(list[4].kind, .emulator)
    }

    func testTabletPrefersCable() {
        let usb = Transport(serial: "R52", state: "device", info: ["usb": "1-1"])
        let wifi = Transport(serial: "10.0.0.5:5555", state: "device", info: [:])
        var tablet = Tablet(id: "R52", name: "Tab", android: "15", transports: [wifi, usb])
        tablet.features = ["R52": ["shell_v2"], "10.0.0.5:5555": ["shell_v2"]]
        XCTAssertEqual(tablet.link?.serial, "R52")
        XCTAssertEqual(tablet.wifiAddress, "10.0.0.5")
        XCTAssertEqual(tablet.subtitle, "Android 15 · кабель и Wi-Fi")

        // Without loaded features a transport is not usable yet.
        tablet.features = ["10.0.0.5:5555": ["shell_v2"]]
        XCTAssertEqual(tablet.link?.serial, "10.0.0.5:5555")
        XCTAssertEqual(tablet.subtitle, "Android 15 · Wi-Fi")

        let waiting = Tablet(id: "X", name: "X", transports: [Transport(serial: "X", state: "unauthorized", info: [:])])
        XCTAssertTrue(waiting.isUnauthorized)
        XCTAssertFalse(waiting.isReady)
    }

    func testWiFiAddress() {
        let output = """
        1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever
        14: wlan0    inet 192.168.1.42/24 brd 192.168.1.255 scope global dynamic wlan0\\       valid_lft 1236sec
        22: rmnet_data0    inet 10.45.0.7/30 scope global rmnet_data0
        """
        XCTAssertEqual(WiFiSetup.wifiAddress(in: output), "192.168.1.42")
        XCTAssertNil(WiFiSetup.wifiAddress(in: "1: lo    inet 127.0.0.1/8 scope host lo"))
        XCTAssertEqual(WiFiSetup.wifiAddress(in: "3: eth0    inet 10.0.2.15/24 brd 10.0.2.255"), "10.0.2.15")
    }

    func testShellQuoting() {
        XCTAssertEqual(Shell.quote("plain"), "'plain'")
        XCTAssertEqual(Shell.quote("it's"), "'it'\\''s'")

        let link = Link(serial: "x", features: ["shell_v2"])
        let many = (0..<2000).map { "/storage/emulated/0/Movies/file number \($0).mp4" }
        let commands = Shell.batches("rm -rf --", many, link: link)
        XCTAssertGreaterThan(commands.count, 1)
        XCTAssertTrue(commands.allSatisfy { $0.hasPrefix("rm -rf --") && $0.utf8.count <= 16_100 })
        let total = commands.map { $0.components(separatedBy: "' '").count }.reduce(0, +)
        XCTAssertEqual(total, many.count)
    }

    func testPaths() {
        XCTAssertEqual(remoteJoin("/storage/emulated/0", "Movies"), "/storage/emulated/0/Movies")
        XCTAssertEqual(remoteJoin("/", "x"), "/x")
        XCTAssertEqual(remoteParent("/storage/emulated/0/Movies"), "/storage/emulated/0")
        XCTAssertEqual(remoteParent("/x"), "/")
        XCTAssertEqual(Session.fileURI("/storage/emulated/0/Movies/Мой фильм #1.mp4"),
                       "file:///storage/emulated/0/Movies/%D0%9C%D0%BE%D0%B9%20%D1%84%D0%B8%D0%BB%D1%8C%D0%BC%20%231.mp4")
    }

    func testFormatting() {
        XCTAssertEqual(plural(1, "файл", "файла", "файлов"), "1 файл")
        XCTAssertEqual(plural(3, "файл", "файла", "файлов"), "3 файла")
        XCTAssertEqual(plural(11, "файл", "файла", "файлов"), "11 файлов")
        XCTAssertEqual(plural(21, "файл", "файла", "файлов"), "21 файл")
        XCTAssertEqual(formatETA(30), "меньше минуты")
        XCTAssertEqual(formatETA(150), "~3 мин")
        XCTAssertEqual(formatETA(4800), "~1 ч 20 мин")
        XCTAssertEqual(formatETA(.infinity), "")
    }

    func testHumanizedErrors() {
        XCTAssertTrue(ADBError.humanize("device unauthorized.\nThis adb server's $ADB_VENDOR_KEYS is not set").contains("Разрешить"))
        XCTAssertEqual(ADBError.humanize("device 'R52' not found"), "Планшет отключился")
        XCTAssertEqual(ADBError.humanize("couldn't create file: No space left on device"), "На планшете закончилось место")
    }

    func testUploadPlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zakidushka-plan-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Отпуск")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("День 1"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Пустая"),
                                                withIntermediateDirectories: true)
        try Data(count: 10).write(to: folder.appendingPathComponent("День 1/a.jpg"))
        try Data(count: 20).write(to: folder.appendingPathComponent("b.jpg"))
        try Data(count: 5).write(to: folder.appendingPathComponent(".DS_Store"))
        let single = root.appendingPathComponent("film.mp4")
        try Data(count: 30).write(to: single)
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = UploadPlan.make([folder, single], into: "/storage/emulated/0/Movies")
        XCTAssertEqual(plan.roots.map(\.name), ["Отпуск", "film.mp4"])
        XCTAssertEqual(Set(plan.files.map(\.remote)), [
            "/storage/emulated/0/Movies/Отпуск/День 1/a.jpg",
            "/storage/emulated/0/Movies/Отпуск/b.jpg",
            "/storage/emulated/0/Movies/film.mp4",
        ])
        XCTAssertEqual(plan.totalBytes, 60)
        XCTAssertTrue(plan.directories.contains("/storage/emulated/0/Movies/Отпуск/Пустая"))

        let onlyFilm = plan.excluding(["Отпуск"])
        XCTAssertEqual(onlyFilm.files.map(\.remote), ["/storage/emulated/0/Movies/film.mp4"])
        XCTAssertTrue(onlyFilm.directories.isEmpty)
        XCTAssertEqual(onlyFilm.roots.map(\.name), ["film.mp4"])
    }
}
