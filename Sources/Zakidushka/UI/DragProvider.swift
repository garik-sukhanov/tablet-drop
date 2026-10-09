import AppKit
import UniformTypeIdentifiers

/// Builds the item provider Finder receives when a row is dragged out.
/// Nothing is fetched until the drop actually happens: Finder calls the
/// handler, we pull the file into a temp folder and hand back its URL.
/// On APFS the copy Finder makes from there is a clone, so it costs no extra disk.
enum DragProvider {
    static func provider(for file: RemoteFile, session: Session) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.name

        let type = file.isDirectory
            ? UTType.folder.identifier
            : (UTType(filenameExtension: (file.name as NSString).pathExtension)?.identifier
               ?? UTType.data.identifier)

        provider.registerFileRepresentation(forTypeIdentifier: type,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            let progress = Progress(totalUnitCount: max(file.size, 1))

            let staging = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(Session.dragStagingPrefix + UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let target = staging.appendingPathComponent(file.name)

            Task { @MainActor in
                session.stageForDrag(file, to: target, progress: progress) { result in
                    switch result {
                    case .success(let url): completion(url, false, nil)
                    case .failure(let error): completion(nil, false, error)
                    }
                }
            }
            return progress
        }
        return provider
    }

    /// Drag staging folders from earlier runs are no longer needed.
    static func cleanUpOldStaging() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        let items = (try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        for item in items where item.lastPathComponent.hasPrefix(Session.dragStagingPrefix) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < dayAgo {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}
