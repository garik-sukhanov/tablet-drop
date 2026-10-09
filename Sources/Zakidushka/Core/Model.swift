import Foundation

struct RemoteFile: Identifiable, Hashable {
    enum Kind: Hashable { case directory, file, other }

    var name: String
    var path: String                  // absolute path on the tablet
    var kind: Kind
    var size: Int64
    var modified: Date?
    var isLink = false

    var id: String { path }
    var isDirectory: Bool { kind == .directory }
    var modifiedSort: Date { modified ?? .distantPast }
}

/// A storage volume: internal memory or an SD card.
struct StorageRoot: Hashable, Identifiable {
    static let internalPath = "/storage/emulated/0"
    static let internalStorage = StorageRoot(path: internalPath, title: "Внутренняя память", removable: false)

    var path: String
    var title: String
    var removable: Bool
    var id: String { path }

    func contains(_ other: String) -> Bool {
        other == path || other.hasPrefix(path + "/")
    }
}

struct StorageSpace: Equatable {
    var total: Int64
    var free: Int64
}

/// A shortcut in the sidebar.
struct Place: Identifiable, Hashable {
    var title: String
    var icon: String
    var path: String
    var id: String { path }

    static func standard(for roots: [StorageRoot]) -> [Place] {
        let base = StorageRoot.internalPath
        var list = [
            Place(title: "Внутренняя память", icon: "internaldrive", path: base),
            Place(title: "Загрузки", icon: "arrow.down.circle", path: base + "/Download"),
            Place(title: "Фильмы", icon: "film", path: base + "/Movies"),
            Place(title: "Картинки", icon: "photo", path: base + "/Pictures"),
            Place(title: "Камера", icon: "camera", path: base + "/DCIM"),
            Place(title: "Музыка", icon: "music.note", path: base + "/Music"),
            Place(title: "Документы", icon: "doc.text", path: base + "/Documents"),
        ]
        for root in roots where root.removable {
            list.append(Place(title: root.title, icon: "sdcard", path: root.path))
        }
        return list
    }
}

struct Transfer: Identifiable {
    enum Direction { case toTablet, toMac }
    enum State: Equatable {
        case waiting, active, done, cancelled
        case failed(String)
    }

    let id = UUID()
    var name: String
    var direction: Direction
    var batch: Int
    var bytes: Int64 = 0
    var total: Int64 = 0
    var state: State = .waiting
    var speed: Double = 0             // bytes per second

    var fraction: Double {
        total > 0 ? min(1, Double(bytes) / Double(total)) : 0
    }

    var isFinished: Bool {
        switch state {
        case .done, .cancelled, .failed: return true
        case .waiting, .active:          return false
        }
    }

    var canRetry: Bool {
        switch state {
        case .failed, .cancelled: return true
        default:                  return false
        }
    }
}

/// Work item for the transfer queue.
struct TransferJob {
    enum Payload {
        case upload(local: URL, remote: String)
        case download(remote: String, mtime: Date?, local: URL)
        case makeDirectories([String])
        case finishUpload([String])               // media scan + refresh after a batch
    }
    var id: UUID
    var payload: Payload
}

/// Everything one drop from the Finder turns into.
struct UploadPlan {
    struct File {
        var local: URL
        var remote: String
        var size: Int64
        var root: String                          // top-level item it belongs to
    }
    struct Root {
        var name: String
        var remote: String
        var isDirectory: Bool
    }

    var remoteDir: String
    var roots: [Root] = []
    var files: [File] = []
    var directories: [String] = []

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { files.isEmpty && directories.isEmpty }

    /// Walks the dropped files and folders. Hidden files inside folders
    /// (.DS_Store and friends) are left behind.
    static func make(_ urls: [URL], into remoteDir: String) -> UploadPlan {
        var plan = UploadPlan(remoteDir: remoteDir)
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let name = url.lastPathComponent
            let remote = remoteJoin(remoteDir, name)
            plan.roots.append(Root(name: name, remote: remote, isDirectory: isDir.boolValue))
            if isDir.boolValue {
                plan.addTree(url, remote: remote, root: remote)
            } else {
                plan.files.append(File(local: url, remote: remote, size: fileSize(url), root: remote))
            }
        }
        return plan
    }

    private mutating func addTree(_ url: URL, remote: String, root: String) {
        directories.append(remote)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let sorted = children.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        for child in sorted {
            let values = try? child.resourceValues(forKeys: Set(keys))
            let childRemote = remoteJoin(remote, child.lastPathComponent)
            if values?.isSymbolicLink == true {
                // Follow links to files; skip links to folders (they can loop).
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir), !isDir.boolValue {
                    files.append(File(local: child, remote: childRemote, size: Self.fileSize(child), root: root))
                }
            } else if values?.isDirectory == true {
                addTree(child, remote: childRemote, root: root)
            } else {
                files.append(File(local: child, remote: childRemote,
                                  size: Int64(values?.fileSize ?? 0), root: root))
            }
        }
    }

    /// The same plan without the given top-level items.
    func excluding(_ names: Set<String>) -> UploadPlan {
        var copy = self
        let skipped = Set(roots.filter { names.contains($0.name) }.map(\.remote))
        copy.roots.removeAll { skipped.contains($0.remote) }
        copy.files.removeAll { skipped.contains($0.root) }
        copy.directories.removeAll { dir in skipped.contains { dir == $0 || dir.hasPrefix($0 + "/") } }
        return copy
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Some dropped items already exist on the tablet — the user decides.
struct UploadConflict {
    var plan: UploadPlan
    var names: [String]

    var involvesFolders: Bool {
        plan.roots.contains { names.contains($0.name) && $0.isDirectory }
    }
}

/// Cancellation is polled from transfer threads, so it lives outside the main actor.
final class CancelFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<UUID>()

    func cancel(_ id: UUID) {
        lock.lock(); ids.insert(id); lock.unlock()
    }

    func clear(_ id: UUID) {
        lock.lock(); ids.remove(id); lock.unlock()
    }

    func contains(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }
}

// MARK: - Paths

func remoteJoin(_ base: String, _ component: String) -> String {
    if component.hasPrefix("/") { return component }
    if base.isEmpty || base == "/" { return "/" + component }
    return base.hasSuffix("/") ? base + component : base + "/" + component
}

func remoteParent(_ path: String) -> String {
    guard path != "/", !path.isEmpty else { return "/" }
    var p = path
    if p.hasSuffix("/") { p.removeLast() }
    guard let idx = p.lastIndex(of: "/") else { return "/" }
    let parent = String(p[p.startIndex..<idx])
    return parent.isEmpty ? "/" : parent
}

// MARK: - Formatting

func formatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
    return f.string(fromByteCount: n)
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 1 else { return "" }
    return formatBytes(Int64(bytesPerSecond)) + "/с"
}

/// "меньше минуты", "~4 мин", "~1 ч 20 мин".
func formatETA(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "" }
    if seconds < 60 { return "меньше минуты" }
    let minutes = Int((seconds / 60).rounded(.up))
    if minutes < 60 { return "~\(minutes) мин" }
    let hours = minutes / 60, rest = minutes % 60
    return rest == 0 ? "~\(hours) ч" : "~\(hours) ч \(rest) мин"
}

/// Russian plural: plural(5, "файл", "файла", "файлов") → "5 файлов".
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let mod100 = n % 100, mod10 = n % 10
    if (11...14).contains(mod100) { return "\(n) \(many)" }
    switch mod10 {
    case 1:     return "\(n) \(one)"
    case 2...4: return "\(n) \(few)"
    default:    return "\(n) \(many)"
    }
}
