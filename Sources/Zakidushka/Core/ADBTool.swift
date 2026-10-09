import Foundation

/// Finds the adb binary and makes sure an adb server is listening on 5037.
/// The app talks to the server over its socket; the binary is needed only
/// to start that server.
enum ADBTool {
    static var candidates: [String] {
        var list: [String] = []
        let env = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = env[key], !root.isEmpty { list.append(root + "/platform-tools/adb") }
        }
        list.append(NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        list.append(PlatformTools.adbURL.path)
        list += [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            "/usr/local/share/android-commandlinetools/platform-tools/adb",
        ]
        return list
    }

    private static let lock = NSLock()
    private static var cached: String?

    static func locate() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached, FileManager.default.isExecutableFile(atPath: cached) { return cached }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            cached = path
            return path
        }
        if let path = viaLoginShell() {
            cached = path
            return path
        }
        return nil
    }

    private static func viaLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v adb"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Starts the adb server unless one already answers. A running server of
    /// another version (Android Studio's, for example) is left alone.
    static func ensureServer() throws {
        if (try? ADBSocket.query("host:version", timeout: 3)) != nil { return }
        guard let adb = locate() else { throw ADBError.adbMissing }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["start-server"]
        // The daemon inherits our descriptors — never hand it a pipe we would wait on.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ADBError.local("Не удалось запустить adb: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        _ = try ADBSocket.query("host:version", timeout: 5)
    }
}

/// Downloads Google's Android Platform Tools when no adb is installed.
enum PlatformTools {
    static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zakidushka", isDirectory: true)
    }

    static var adbURL: URL { folder.appendingPathComponent("platform-tools/adb") }

    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = try await ZipDownload(progress: progress).run(downloadURL)
        defer { try? fm.removeItem(at: zip) }

        let target = folder.appendingPathComponent("platform-tools")
        try? fm.removeItem(at: target)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, folder.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0, fm.isExecutableFile(atPath: adbURL.path) else {
            throw ADBError.local("Архив скачался, но adb в нём не нашёлся")
        }
    }
}

/// URLSession download with progress, wrapped for async/await.
private final class ZipDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(ADBError.local("Сервер Google ответил кодом \(http.statusCode)")))
            return
        }
        // The file at `location` disappears when this method returns.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("platform-tools-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
