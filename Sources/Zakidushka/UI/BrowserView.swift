import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @ObservedObject var session: Session
    let tablet: Tablet
    @EnvironmentObject var app: AppState
    @AppStorage("showHidden") private var showHidden = false

    @State private var selection = Set<RemoteFile.ID>()
    @State private var filter = ""
    @State private var renaming: RemoteFile?
    @State private var renameText = ""
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var confirmDelete = false
    @State private var dropTargeted = false
    @State private var sortOrder = [KeyPathComparator(\RemoteFile.name, comparator: .localizedStandard)]

    private var visibleFiles: [RemoteFile] {
        var list = session.files
        if !showHidden { list = list.filter { !$0.name.hasPrefix(".") } }
        if !filter.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        let order = sortOrder
        return list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            for comparator in order {
                let result = comparator.compare(a, b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return false
        }
    }

    private var selectedFiles: [RemoteFile] {
        session.files.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            content
            TransfersBar(session: session)
        }
        .navigationTitle(tablet.name)
        .navigationSubtitle(session.folderTitle)
        .toolbar { toolbarItems }
        .searchable(text: $filter, placement: .toolbar, prompt: "Фильтр")
        .onAppear { session.start() }
        .onChange(of: session.path) { selection.removeAll() }
        .onChange(of: session.newFolderRequested) {
            if session.newFolderRequested {
                session.newFolderRequested = false
                folderName = ""
                creatingFolder = true
            }
        }
        .sheet(item: $renaming) { file in
            PromptSheet(title: "Переименовать", label: file.name,
                        text: $renameText, confirm: "Переименовать") {
                session.rename(file, to: renameText)
            }
        }
        .sheet(isPresented: $creatingFolder) {
            PromptSheet(title: "Новая папка", label: "В «\(session.folderTitle)»",
                        text: $folderName, confirm: "Создать") {
                session.makeDirectory(named: folderName)
            }
        }
        .confirmationDialog("Удалить с планшета \(plural(selectedFiles.count, "объект", "объекта", "объектов"))?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                session.delete(selectedFiles)
                selection.removeAll()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("В корзину они не попадут — удаление насовсем.")
        }
        .confirmationDialog(conflictTitle, isPresented: conflictShown, titleVisibility: .visible,
                            presenting: session.conflict) { conflict in
            Button("Заменить") { session.resolve(conflict, replace: true) }
            if conflict.names.count < conflict.plan.roots.count {
                Button("Скопировать только новые") { session.resolve(conflict, replace: false) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { conflict in
            Text(conflictMessage(conflict))
        }
    }

    // MARK: - Pieces

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button { session.goUp() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(!session.canGoUp)
                .help("Наверх (⌘↑)")

            let crumbs = session.breadcrumbs
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button(crumb.title) { session.navigate(to: crumb.path) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(index == crumbs.count - 1 ? Color.primary : Color.secondary)
            }
            Spacer()
            if session.loading || session.preparing {
                ProgressView().controlSize(.small)
            }
            if let space = session.space {
                Text("Свободно \(formatBytes(space.free)) из \(formatBytes(space.total))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(space.free < 2_000_000_000 ? Color.orange : .secondary)
                    .help("Место на «\(session.root.title)»")
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Открываю «\(tablet.name)»…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.orange)
                Text("Не получилось открыть планшет").font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
                Button("Повторить") { session.reload() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

        case .ready:
            fileTable
                .overlay { emptyHint }
                .overlay(alignment: .top) { banner }
        }
    }

    private var fileTable: some View {
        Table(of: RemoteFile.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Имя", value: \.name, comparator: .localizedStandard) { file in
                HStack(spacing: 6) {
                    Image(systemName: iconName(file))
                        .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    Text(file.name).lineLimit(1)
                    if file.isLink {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 220, ideal: 420)

            TableColumn("Размер", value: \.size) { file in
                Text(file.isDirectory ? "—" : formatBytes(file.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Изменён", value: \.modifiedSort) { file in
                Text(file.modified.map { Self.dateFormatter.string(from: $0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
        } rows: {
            ForEach(visibleFiles) { file in
                TableRow(file)
                    .itemProvider { DragProvider.provider(for: file, session: session) }
            }
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            open(ids)
        }
        .onDeleteCommand {
            if !selection.isEmpty { confirmDelete = true }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.upload(urls, to: session.path)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var emptyHint: some View {
        if visibleFiles.isEmpty, !session.loading {
            VStack(spacing: 8) {
                Image(systemName: filter.isEmpty ? "tray.and.arrow.down" : "magnifyingglass")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text(filter.isEmpty ? "Папка пуста" : "Ничего не найдено")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if filter.isEmpty {
                    Text("Перетащите сюда файлы с Mac — они скопируются на планшет")
                        .foregroundStyle(.tertiary)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<RemoteFile.ID>) -> some View {
        let files = session.files.filter { ids.contains($0.id) }
        if files.isEmpty {
            Button("Новая папка…") { folderName = ""; creatingFolder = true }
            Button("Загрузить на планшет…") { app.chooseFilesForUpload() }
            Button("Обновить") { session.reload() }
        } else {
            if files.count == 1, files[0].isDirectory {
                Button("Открыть") { open(ids) }
            }
            Button("Скачать в «\(session.downloadFolder.lastPathComponent)»") {
                session.download(files, to: session.downloadFolder)
            }
            Button("Скачать в…") { chooseFolderAndDownload(files) }
            Divider()
            if files.count == 1 {
                Button("Переименовать…") {
                    renameText = files[0].name
                    renaming = files[0]
                }
                Button("Скопировать путь") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(files[0].path, forType: .string)
                }
            }
            Divider()
            Button("Удалить…", role: .destructive) {
                selection = ids
                confirmDelete = true
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let message = session.banner {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white)
                Text(message).foregroundStyle(.white).lineLimit(3)
                Spacer()
                Button {
                    session.banner = nil
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.white)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Обновить (⌘R)")
                .accessibilityLabel("Обновить")

            Button { folderName = ""; creatingFolder = true } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("Новая папка (⇧⌘N)")
            .accessibilityLabel("Новая папка")

            Button { app.chooseFilesForUpload() } label: {
                Image(systemName: "arrow.up.doc")
            }
            .help("Загрузить файлы на планшет (⌘O)")
            .accessibilityLabel("Загрузить на планшет")

            Button {
                session.download(selectedFiles, to: session.downloadFolder)
            } label: {
                Image(systemName: "arrow.down.doc")
            }
            .disabled(selection.isEmpty)
            .help("Скачать выбранное на Mac, в «Загрузки»")
            .accessibilityLabel("Скачать на Mac")

            Button { confirmDelete = true } label: {
                Image(systemName: "trash")
            }
            .disabled(selection.isEmpty)
            .help("Удалить выбранное с планшета")
            .accessibilityLabel("Удалить")
        }
    }

    // MARK: - Conflict dialog

    private var conflictShown: Binding<Bool> {
        Binding(get: { session.conflict != nil },
                set: { if !$0 { session.conflict = nil } })
    }

    private var conflictTitle: String {
        guard let conflict = session.conflict else { return "" }
        if conflict.names.count == 1 { return "«\(conflict.names[0])» уже есть на планшете" }
        return "\(plural(conflict.names.count, "объект", "объекта", "объектов")) уже есть на планшете"
    }

    private func conflictMessage(_ conflict: UploadConflict) -> String {
        var text = ""
        if conflict.names.count > 1 {
            let shown = conflict.names.prefix(4).map { "«\($0)»" }.joined(separator: ", ")
            let rest = conflict.names.count - 4
            text = rest > 0 ? "\(shown) и ещё \(rest). " : "\(shown). "
        }
        if conflict.involvesFolders {
            text += "Папки объединятся, файлы с одинаковыми именами заменятся."
        } else {
            text += "Старые версии заменятся новыми."
        }
        return text
    }

    // MARK: - Actions

    private func open(_ ids: Set<RemoteFile.ID>) {
        let files = session.files.filter { ids.contains($0.id) }
        guard let first = files.first else { return }
        if first.isDirectory {
            session.navigate(to: first.path)
        } else {
            session.download(files, to: session.downloadFolder)
        }
    }

    private func chooseFolderAndDownload(_ files: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Сохранить сюда"
        if panel.runModal() == .OK, let url = panel.url {
            session.download(files, to: url)
        }
    }

    private func iconName(_ file: RemoteFile) -> String {
        if file.isDirectory { return "folder.fill" }
        switch (file.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "svg", "dng": return "photo"
        case "mp4", "mov", "mkv", "avi", "webm", "m4v", "3gp", "wmv", "flv", "ts":   return "film"
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "wma":              return "music.note"
        case "pdf":                                                                 return "doc.richtext"
        case "epub", "fb2", "mobi", "djvu":                                         return "book"
        case "zip", "gz", "tar", "bz2", "xz", "7z", "rar":                          return "doc.zipper"
        case "apk", "xapk", "apks":                                                 return "app.badge"
        case "txt", "md", "rtf", "doc", "docx", "odt":                              return "doc.text"
        case "xls", "xlsx", "csv", "numbers":                                       return "tablecells"
        default:                                                                    return "doc"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Small sheet used for both rename and "new folder".
struct PromptSheet: View {
    let title: String
    let label: String
    @Binding var text: String
    let confirm: String
    let action: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            TextField("Имя", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        action()
        dismiss()
    }
}
