import Foundation

/// Owns one sync connection on its own serial queue, so callers never need
/// locks. The connection is reopened when the tablet switches between cable
/// and Wi-Fi, or after any error (a failed sync command closes it anyway).
final class DeviceLink {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var sync: SyncSession?

    init(label: String) {
        queue = DispatchQueue(label: "me.garik.Zakidushka.\(label)", qos: .userInitiated)
    }

    func perform<T>(_ link: Link, _ body: @escaping (SyncSession) throws -> T,
                    then: @escaping (Result<T, Error>) -> Void) {
        queue.async { then(self.attempt(link, body)) }
    }

    /// Runs work that needs no sync connection (shell commands) in the same order.
    func run<T>(_ body: @escaping () throws -> T, then: @escaping (Result<T, Error>) -> Void) {
        queue.async { then(Result { try body() }) }
    }

    func close() { queue.async { self.drop() } }

    private func attempt<T>(_ link: Link, _ body: (SyncSession) throws -> T) -> Result<T, Error> {
        var reused = false
        do {
            let session = try connection(for: link, reused: &reused)
            return .success(try body(session))
        } catch {
            drop()
            // A kept connection may have died while idle (cable replugged,
            // tablet asleep) — one fresh try before giving up.
            guard reused, case ADBError.io = error else { return .failure(error) }
            do {
                let session = try connection(for: link, reused: &reused)
                return .success(try body(session))
            } catch {
                drop()
                return .failure(error)
            }
        }
    }

    private func connection(for link: Link, reused: inout Bool) throws -> SyncSession {
        lock.lock(); let current = sync; lock.unlock()
        if let current, current.serial == link.serial {
            reused = true
            return current
        }
        drop()
        let fresh = try SyncSession(link: link)
        lock.lock(); sync = fresh; lock.unlock()
        reused = false
        return fresh
    }

    private func drop() {
        lock.lock(); let current = sync; sync = nil; lock.unlock()
        current?.close()
    }
}

/// Browser state and transfer queue for one tablet.
@MainActor
final class Session: ObservableObject {
    enum State: Equatable {
        case loading, ready
        case failed(String)
    }

    let tabletID: String
    private unowned let hub: DeviceHub

    @Published private(set) var state: State = .loading
    @Published private(set) var path = ""
    @Published private(set) var files: [RemoteFile] = []
    @Published private(set) var loading = false
    @Published private(set) var preparing = false
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var roots: [StorageRoot] = [.internalStorage]
    @Published private(set) var space: StorageSpace?
    @Published var banner: String?
    @Published var conflict: UploadConflict?
    @Published var newFolderRequested = false

    /// Where downloads land when they are not dragged to a specific place.
    var downloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    private let browse = DeviceLink(label: "browse")
    private let transferLink = DeviceLink(label: "transfer")
    private let dragLink = DeviceLink(label: "drag")      // drag-outs never wait behind a long upload

    private var pending: [TransferJob] = []
    private var jobs: [UUID: TransferJob] = [:]           // kept for "retry"
    private var running = false
    private var batch = 0
    private let cancelFlags = CancelFlags()
    private var spaceRoot: String?
    private var started = false

    init(tabletID: String, hub: DeviceHub) {
        self.tabletID = tabletID
        self.hub = hub
    }

    private var link: Link? { hub.link(for: tabletID) }

    // MARK: - Where we are

    var root: StorageRoot { roots.first { $0.contains(path) } ?? .internalStorage }
    var places: [Place] { Place.standard(for: roots) }
    var canGoUp: Bool { !path.isEmpty && path != root.path }

    var folderTitle: String {
        path == root.path ? root.title : (path as NSString).lastPathComponent
    }

    /// "Внутренняя память › Movies › Сериалы".
    var breadcrumbs: [(title: String, path: String)] {
        let root = self.root
        var crumbs = [(title: root.title, path: root.path)]
        guard path.hasPrefix(root.path + "/") else { return crumbs }
        var current = root.path
        for part in path.dropFirst(root.path.count + 1).split(separator: "/") {
            current += "/" + part
            crumbs.append((title: String(part), path: current))
        }
        return crumbs
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        loadRoots()
        navigate(to: StorageRoot.internalPath)
    }

    /// Called whenever the tablet is reachable again (cable back, Wi-Fi up).
    func deviceReady() {
        guard started else { return }
        if case .failed = state {
            loadRoots()
            navigate(to: path.isEmpty ? StorageRoot.internalPath : path)
        }
        if !running, !pending.isEmpty { pump() }
    }

    func close() {
        browse.close()
        transferLink.close()
        dragLink.close()
    }

    // MARK: - Browsing

    func navigate(to newPath: String) {
        guard let link else {
            state = .failed("Планшет отключён")
            return
        }
        loading = true
        browse.perform(link, { sync in try Session.list(sync, newPath) }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let items):
                    self.path = newPath
                    self.files = items
                    self.state = .ready
                    self.refreshSpace()
                case .failure(let error):
                    if self.state == .ready {
                        self.report(error)
                    } else {
                        self.state = .failed(error.localizedDescription)
                    }
                }
            }
        })
    }

    func reload() {
        navigate(to: path.isEmpty ? StorageRoot.internalPath : path)
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: remoteParent(path))
    }

    nonisolated static func list(_ sync: SyncSession, _ path: String) throws -> [RemoteFile] {
        guard let info = try sync.stat(path) else {
            throw ADBError.device("Папка «\((path as NSString).lastPathComponent)» не найдена на планшете")
        }
        guard info.isDirectory else {
            throw ADBError.device("«\((path as NSString).lastPathComponent)» — это файл, а не папка")
        }
        var result: [RemoteFile] = []
        for entry in try sync.list(path) {
            let full = remoteJoin(path, entry.name)
            var file = RemoteFile(name: entry.name, path: full,
                                  kind: entry.isDirectory ? .directory : (entry.isRegular ? .file : .other),
                                  size: entry.size, modified: entry.mtime)
            if entry.isSymlink {
                file.isLink = true
                if let target = try sync.stat(full) {
                    file.kind = target.isDirectory ? .directory : .file
                    file.size = target.size
                    file.modified = target.mtime
                }
            }
            result.append(file)
        }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func loadRoots() {
        guard let link else { return }
        browse.perform(link, { sync -> [StorageRoot] in
            // SD cards and USB sticks show up as /storage/XXXX-XXXX.
            let names = try sync.list("/storage")
                .filter { $0.isDirectory && $0.name != "emulated" && $0.name != "self" }
                .map(\.name)
                .sorted()
            var roots = [StorageRoot.internalStorage]
            for (index, name) in names.enumerated() {
                let title = names.count == 1 ? "SD-карта" : "SD-карта \(index + 1)"
                roots.append(StorageRoot(path: "/storage/\(name)", title: title, removable: true))
            }
            return roots
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let roots) = result, self?.roots != roots { self?.roots = roots }
            }
        })
    }

    private func refreshSpace(force: Bool = false) {
        let rootPath = root.path
        guard force || spaceRoot != rootPath, let link else { return }
        spaceRoot = rootPath
        browse.run({ try Session.readSpace(link, rootPath) }, then: { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let space) = result { self?.space = space }
            }
        })
    }

    nonisolated static func readSpace(_ link: Link, _ path: String) throws -> StorageSpace {
        let out = try Shell.check(link, "stat -f -c '%S %b %a' " + Shell.quote(path), timeout: 10)
        let numbers = out.split(whereSeparator: \.isWhitespace).compactMap { Int64($0) }
        guard numbers.count == 3 else { throw ADBError.protocolError("stat -f: \(out)") }
        return StorageSpace(total: numbers[0] * numbers[1], free: numbers[0] * numbers[2])
    }

    // MARK: - Changes on the tablet

    func rename(_ file: RemoteFile, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != file.name, let link else { return }
        guard !name.contains("/") else {
            banner = "В имени не может быть «/»"
            return
        }
        let target = remoteJoin(remoteParent(file.path), name)
        let caseOnly = name.lowercased() == file.name.lowercased()
        browse.perform(link, { sync in
            if !caseOnly, try sync.stat(target) != nil {
                throw ADBError.device("«\(name)» уже есть в этой папке")
            }
            try Shell.check(link, "mv -- \(Shell.quote(file.path)) \(Shell.quote(target))")
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result { self?.report(error) }
                self?.reload()
            }
        })
    }

    func delete(_ items: [RemoteFile]) {
        guard !items.isEmpty, let link else { return }
        let paths = items.map(\.path)
        loading = true
        browse.run({
            for command in Shell.batches("rm -rf --", paths, link: link) {
                try Shell.check(link, command, timeout: 600)
            }
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result { self.report(error) }
                self.reload()
                self.refreshSpace(force: true)
            }
        })
    }

    func makeDirectory(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let link else { return }
        guard !name.contains("/") else {
            banner = "В имени не может быть «/»"
            return
        }
        let target = remoteJoin(path, name)
        browse.run({
            try Shell.check(link, "mkdir -- \(Shell.quote(target))")
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result { self?.report(error) }
                self?.reload()
            }
        })
    }

    // MARK: - Mac → tablet

    func upload(_ urls: [URL], to remoteDir: String) {
        let urls = urls.filter { $0.isFileURL && !Self.isOwnDragStaging($0) }
        guard !urls.isEmpty else { return }
        guard let link else {
            banner = "Планшет отключён"
            return
        }
        preparing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = UploadPlan.make(urls, into: remoteDir)
            DispatchQueue.main.async { self.check(plan, link: link) }
        }
    }

    /// Looks for name clashes and free space before anything is copied.
    private func check(_ plan: UploadPlan, link: Link) {
        let rootPath = (roots.first { $0.contains(plan.remoteDir) } ?? .internalStorage).path
        browse.perform(link, { sync -> ([String], StorageSpace?) in
            var clashes: [String] = []
            for root in plan.roots {
                if try sync.stat(root.remote) != nil { clashes.append(root.name) }
            }
            return (clashes, try? Session.readSpace(link, rootPath))
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                switch result {
                case .failure(let error):
                    self.report(error)
                case .success(let (clashes, space)):
                    if let space, rootPath == self.root.path { self.space = space }
                    if let space, plan.totalBytes > space.free {
                        self.banner = "Не хватит места на планшете: нужно \(formatBytes(plan.totalBytes)), "
                                    + "свободно \(formatBytes(space.free))"
                        return
                    }
                    if clashes.isEmpty {
                        self.enqueue(plan)
                    } else {
                        self.conflict = UploadConflict(plan: plan, names: clashes)
                    }
                }
            }
        })
    }

    func resolve(_ conflict: UploadConflict, replace: Bool) {
        self.conflict = nil
        let plan = replace ? conflict.plan : conflict.plan.excluding(Set(conflict.names))
        if !plan.isEmpty { enqueue(plan) }
    }

    private func enqueue(_ plan: UploadPlan) {
        startBatchIfIdle()
        if !plan.directories.isEmpty {
            pending.append(TransferJob(id: UUID(), payload: .makeDirectories(plan.directories)))
        }
        for file in plan.files {
            var row = Transfer(name: file.local.lastPathComponent, direction: .toTablet, batch: batch)
            row.total = file.size
            transfers.append(row)
            let job = TransferJob(id: row.id, payload: .upload(local: file.local, remote: file.remote))
            jobs[row.id] = job
            pending.append(job)
        }
        pending.append(TransferJob(id: UUID(), payload: .finishUpload(plan.roots.map(\.remote))))
        pump()
    }

    // MARK: - Tablet → Mac

    func download(_ items: [RemoteFile], to destination: URL) {
        guard !items.isEmpty, let link else { return }
        preparing = true
        transferLink.perform(link, { sync -> [(RemoteFile, URL)] in
            var plan: [(RemoteFile, URL)] = []
            for item in items {
                let local = destination.appendingPathComponent(item.name)
                if item.isDirectory {
                    try Session.walk(sync, item.path, local: local, into: &plan)
                } else {
                    plan.append((item, local))
                }
            }
            return plan
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                switch result {
                case .success(let plan):
                    self.startBatchIfIdle()
                    for (file, local) in plan {
                        let target = Session.uniqueURL(local)
                        var row = Transfer(name: target.lastPathComponent, direction: .toMac, batch: self.batch)
                        row.total = file.size
                        self.transfers.append(row)
                        let job = TransferJob(id: row.id,
                                              payload: .download(remote: file.path, mtime: file.modified, local: target))
                        self.jobs[row.id] = job
                        self.pending.append(job)
                    }
                    self.pump()
                case .failure(let error):
                    self.report(error)
                }
            }
        })
    }

    nonisolated static func walk(_ sync: SyncSession, _ remote: String, local: URL,
                                 into plan: inout [(RemoteFile, URL)]) throws {
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for entry in try list(sync, remote) {
            let childLocal = local.appendingPathComponent(entry.name)
            if entry.isDirectory {
                if !entry.isLink {                     // linked folders can loop
                    try walk(sync, entry.path, local: childLocal, into: &plan)
                }
            } else if entry.kind == .file {
                plan.append((entry, childLocal))
            }
        }
    }

    nonisolated static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: - Queue

    func cancel(_ id: UUID) {
        cancelFlags.cancel(id)
        if let idx = index(of: id), transfers[idx].state == .waiting {
            transfers[idx].state = .cancelled
            pending.removeAll { $0.id == id }
        }
    }

    func cancelAll() {
        for transfer in transfers where !transfer.isFinished { cancel(transfer.id) }
    }

    func retry(_ id: UUID) {
        guard let job = jobs[id], let idx = index(of: id), transfers[idx].canRetry else { return }
        startBatchIfIdle()
        cancelFlags.clear(id)
        transfers[idx].state = .waiting
        transfers[idx].bytes = 0
        transfers[idx].speed = 0
        transfers[idx].batch = batch
        pending.append(job)
        if case .upload(_, let remote) = job.payload {
            pending.append(TransferJob(id: UUID(), payload: .finishUpload([remote])))
        }
        pump()
    }

    func clearFinished() {
        let finished = transfers.filter(\.isFinished).map(\.id)
        transfers.removeAll { $0.isFinished }
        for id in finished { jobs[id] = nil }
    }

    /// A new batch starts when nothing is queued — the progress bar then
    /// counts only what was added since.
    private func startBatchIfIdle() {
        if !running && pending.isEmpty { batch += 1 }
    }

    private func index(of id: UUID) -> Int? {
        transfers.firstIndex { $0.id == id }
    }

    private func pump() {
        guard !running, !pending.isEmpty else { return }
        guard let link else { return }                  // resumes in deviceReady()
        let job = pending.removeFirst()
        running = true

        let jobID = job.id
        if let idx = index(of: jobID) {
            transfers[idx].state = .active
            transfers[idx].bytes = 0
        }

        let flags = cancelFlags
        var lastTick = Date()
        var lastBytes: Int64 = 0
        let onProgress: (Int64) -> Bool = { [weak self] done in
            let now = Date()
            let elapsed = now.timeIntervalSince(lastTick)
            if elapsed >= 0.2 {
                let speed = Double(done - lastBytes) / elapsed
                lastTick = now
                lastBytes = done
                DispatchQueue.main.async {
                    guard let self, let idx = self.index(of: jobID) else { return }
                    self.transfers[idx].bytes = done
                    let old = self.transfers[idx].speed
                    self.transfers[idx].speed = old == 0 ? speed : old * 0.7 + speed * 0.3
                }
            }
            return !flags.contains(jobID)
        }

        transferLink.perform(link, { sync in
            switch job.payload {
            case .upload(let local, let remote):
                try sync.push(local, to: remote, progress: onProgress)
            case .download(let remote, let mtime, let local):
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try sync.pull(remote, to: local, mtime: mtime, progress: onProgress)
            case .makeDirectories(let directories):
                for command in Shell.batches("mkdir -p --", directories, link: link) {
                    try Shell.check(link, command)
                }
            case .finishUpload(let paths):
                Session.scanMedia(paths, link: link)
            }
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                if let idx = self.index(of: jobID) {
                    switch result {
                    case .success:
                        self.transfers[idx].state = .done
                        self.transfers[idx].bytes = self.transfers[idx].total
                    case .failure(ADBError.cancelled):
                        self.transfers[idx].state = .cancelled
                    case .failure(let error):
                        self.transfers[idx].state = .failed(error.localizedDescription)
                    }
                } else if case .failure(let error) = result {
                    self.report(error)                  // folder creation failed
                }
                if case .finishUpload = job.payload {
                    self.reload()
                    self.refreshSpace(force: true)
                }
                self.pump()
            }
        })
    }

    /// Asks Android to index new files right away, so photos and films show
    /// up in Gallery and video players without waiting for a rescan.
    nonisolated static func scanMedia(_ paths: [String], link: Link) {
        let commands = paths.map {
            "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(Shell.quote(fileURI($0))) >/dev/null 2>&1"
        }
        var index = 0
        while index < commands.count {
            let slice = commands[index..<min(index + 20, commands.count)]
            _ = try? Shell.run(link, slice.joined(separator: "; "), timeout: 120)
            index += 20
        }
    }

    nonisolated static func fileURI(_ path: String) -> String {
        "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    // MARK: - Drag to Finder

    /// Fetches one entry for a Finder drop into a temp folder and reports into
    /// the Progress object Finder shows.
    func stageForDrag(_ file: RemoteFile, to target: URL, progress: Progress,
                      completion: @escaping (Result<URL, Error>) -> Void) {
        guard let link else {
            completion(.failure(ADBError.device("Планшет отключён")))
            return
        }
        var row = Transfer(name: file.name, direction: .toMac, batch: batch)
        row.total = file.size
        row.state = .active
        transfers.append(row)
        let rowID = row.id

        var lastTick = Date.distantPast
        let onProgress: (Int64, Int64) -> Bool = { [weak self] done, total in
            progress.completedUnitCount = done
            progress.totalUnitCount = max(total, 1)
            let now = Date()
            if now.timeIntervalSince(lastTick) >= 0.2 {
                lastTick = now
                DispatchQueue.main.async {
                    guard let self, let idx = self.index(of: rowID) else { return }
                    self.transfers[idx].bytes = done
                    self.transfers[idx].total = total
                }
            }
            return !progress.isCancelled
        }

        dragLink.perform(link, { sync -> URL in
            if file.isDirectory {
                var plan: [(RemoteFile, URL)] = []
                try Session.walk(sync, file.path, local: target, into: &plan)
                let total = plan.reduce(Int64(0)) { $0 + $1.0.size }
                var base: Int64 = 0
                for (entry, local) in plan {
                    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try sync.pull(entry.path, to: local, mtime: entry.modified) { onProgress(base + $0, total) }
                    base += entry.size
                }
            } else {
                try sync.pull(file.path, to: target, mtime: file.modified) { onProgress($0, file.size) }
            }
            return target
        }, then: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if let idx = self.index(of: rowID) {
                    switch result {
                    case .success:
                        self.transfers[idx].state = .done
                        self.transfers[idx].bytes = self.transfers[idx].total
                    case .failure(ADBError.cancelled):
                        self.transfers[idx].state = .cancelled
                    case .failure(let error):
                        self.transfers[idx].state = .failed(error.localizedDescription)
                    }
                }
                completion(result)
            }
        })
    }

    nonisolated static let dragStagingPrefix = "zakidushka-drag-"

    /// Rows dragged from our own table come back as temp files — ignore them
    /// instead of copying a file onto the tablet it came from.
    private static func isOwnDragStaging(_ url: URL) -> Bool {
        url.path.contains("/" + dragStagingPrefix)
    }

    // MARK: - Errors

    private func report(_ error: Error) {
        if case ADBError.cancelled = error { return }
        let message = error.localizedDescription
        banner = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.banner == message { self?.banner = nil }
        }
    }
}
