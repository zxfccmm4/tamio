//
//  FileTransferView.swift
//  TamioMobile
//
//  Concurrent SFTP built on TamioModule's FileBrowser and TransferQueue:
//  - iPad (regular width >= 720pt): dual-pane browser (Local + Server, or any
//    two servers for direct relay copies), mirroring the Mac app.
//  - iPhone (compact): full-screen browser with instant Local/Remote switcher.
//  - Non-blocking background TransferQueue bar & expandable sheet with speed,
//    progress, cancel, retry, and collision confirmation (Replace / Keep Both /
//    Skip).
//  - Inline Runestone remote text editing via RemoteFileEditorView.
//

import SPIndicator
import SwiftUI
import TamioDesign
import TamioModule
import UIKit
import UniformTypeIdentifiers

enum FilesPreference {
    static let showsHiddenKey = "sb.moe.tamio.files.showsHidden"
}

@MainActor
final class MobileFilePaneModel: ObservableObject {
    enum SortColumn: String, CaseIterable {
        case name = "Name"
        case modified = "Modified"
        case size = "Size"
        case kind = "Kind"

        var localizedTitle: String {
            switch self {
            case .name: return String(localized: "Name")
            case .modified: return String(localized: "Modified")
            case .size: return String(localized: "Size")
            case .kind: return String(localized: "Kind")
            }
        }
    }

    @Published var browser: FileBrowser
    @Published var filter = ""
    @Published var sort: SortColumn = .name
    @Published var ascending = true

    init(browser: FileBrowser) {
        self.browser = browser
        browser.reload()
    }

    func switchTo(_ next: FileBrowser) {
        filter = ""
        browser = next
        next.reload()
    }

    func entries(_ all: [FileEntry], showsHidden: Bool) -> [FileEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = showsHidden ? all : all.filter { !$0.name.hasPrefix(".") }
        let shown = needle.isEmpty ? visible : visible.filter { $0.name.lowercased().contains(needle) }
        return shown.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let ordered: Bool
            switch sort {
            case .name: ordered = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modified: ordered = (lhs.modified ?? .distantPast) < (rhs.modified ?? .distantPast)
            case .size: ordered = (lhs.size ?? 0) < (rhs.size ?? 0)
            case .kind: ordered = lhs.kind.localizedStandardCompare(rhs.kind) == .orderedAscending
            }
            return ascending ? ordered : !ordered
        }
    }
}

struct FileTransferView: View {
    @ObservedObject var context: FileTransferContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var queue = TransferQueue.shared
    @ObservedObject private var directories = TerminalDirectories.shared

    @StateObject private var localPane: MobileFilePaneModel
    @StateObject private var remotePane: MobileFilePaneModel
    @State private var activeCompactPane: CompactPane = .remote
    @State private var pageWidth: CGFloat = 0
    @State private var showsQueueSheet = false
    @State private var editing: EditedFile?
    @State private var pendingCollision: PendingTransfer?
    @State private var followedSerial: Int?

    enum CompactPane: String, CaseIterable {
        case remote = "Server"
        case local = "Local"
    }

    struct EditedFile: Identifiable {
        let path: String
        var id: String { path }
    }

    struct PendingTransfer: Identifiable {
        let id = UUID()
        let sources: [String]
        let from: RDMachine?
        let to: RDMachine?
        let destination: String
        let conflictNames: [String]
        let onDone: () -> Void
    }

    private var dualPane: Bool { sizeClass == .regular && pageWidth >= 720 }

    init(context: FileTransferContext) {
        self.context = context
        _localPane = StateObject(wrappedValue: MobileFilePaneModel(browser: LocalBrowser()))
        _remotePane = StateObject(wrappedValue: MobileFilePaneModel(browser: RemoteBrowser(machine: context.machine)))
    }

    var body: some View {
        VStack(spacing: 0) {
            if dualPane {
                HStack(spacing: 0) {
                    MobileBrowserPane(
                        model: localPane,
                        peer: remotePane,
                        context: context,
                        onEdit: { editing = EditedFile(path: $0) },
                        onTransfer: startTransfer
                    )
                    Hairline(vertical: true)
                    MobileBrowserPane(
                        model: remotePane,
                        peer: localPane,
                        context: context,
                        onEdit: { editing = EditedFile(path: $0) },
                        onTransfer: startTransfer
                    )
                }
            } else {
                Picker("Pane", selection: $activeCompactPane) {
                    Text(remotePane.browser.title).tag(CompactPane.remote)
                    Text(localPane.browser.title).tag(CompactPane.local)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, RX.Space.s4)
                .padding(.vertical, RX.Space.s2)

                if activeCompactPane == .remote {
                    MobileBrowserPane(
                        model: remotePane,
                        peer: localPane,
                        context: context,
                        onEdit: { editing = EditedFile(path: $0) },
                        onTransfer: startTransfer
                    )
                } else {
                    MobileBrowserPane(
                        model: localPane,
                        peer: remotePane,
                        context: context,
                        onEdit: { editing = EditedFile(path: $0) },
                        onTransfer: startTransfer
                    )
                }
            }

            if !queue.jobs.isEmpty {
                TransferBarStrip(showsSheet: $showsQueueSheet)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle(context.machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsQueueSheet = true
                } label: {
                    Label("Transfers", systemImage: queue.active.isEmpty ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill")
                }
                .badge(queue.active.count)

                Button {
                    UIBridge.openFileContainer()
                } label: {
                    Label("Open Files App", systemImage: "folder")
                }

                Button(role: .destructive) {
                    FileTransferManager.shared.end(for: context.id)
                    dismiss()
                } label: {
                    Label("Close", rx: "xmark")
                }
            }
        }
        .sheet(isPresented: $showsQueueSheet) {
            NavigationStack {
                TransferQueueSheet()
            }
        }
        .fullScreenCover(item: $editing) { file in
            RemoteFileEditorView(context: context, remotePath: file.path)
        }
        .confirmationDialog(
            collisionTitle,
            isPresented: Binding(get: { pendingCollision != nil }, set: { if !$0 { pendingCollision = nil } }),
            titleVisibility: .visible
        ) {
            if let pending = pendingCollision {
                Button("Replace", role: .destructive) {
                    enqueueTransfer(pending, collision: .replace)
                    pendingCollision = nil
                }
                Button("Keep Both") {
                    enqueueTransfer(pending, collision: .keepBoth)
                    pendingCollision = nil
                }
                Button("Skip") {
                    enqueueTransfer(pending, collision: .skip)
                    pendingCollision = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingCollision = nil
                }
            }
        } message: {
            Text(collisionMessage)
        }
        .onAppear {
            wireQueueCompletion()
            followTerminalDirectory()
        }
        .onChange(of: directories.latest[context.machine.id]) { _, _ in
            followTerminalDirectory()
        }
    }

    private var collisionTitle: String {
        guard let names = pendingCollision?.conflictNames else { return "" }
        if names.count == 1 {
            return String(localized: "“\(names[0])” already exists")
        }
        return String(localized: "\(names.count) items already exist")
    }

    private var collisionMessage: String {
        guard let names = pendingCollision?.conflictNames else { return "" }
        let preview = names.prefix(3).joined(separator: ", ")
        return String(localized: "Choose how to handle existing items in the destination folder (\(preview)).")
    }

    private func wireQueueCompletion() {
        TransferQueue.shared.onFinish = { [weak localPane, weak remotePane] job in
            if job.to == nil {
                localPane?.browser.reload()
            }
            if let dest = job.to {
                if remotePane?.browser.machine?.id == dest.id { remotePane?.browser.reload() }
                if localPane?.browser.machine?.id == dest.id { localPane?.browser.reload() }
            }
            if job.state == .done {
                let indicator = SPIndicatorView(
                    title: String(localized: "Transfer Completed"),
                    message: job.title,
                    preset: .done
                )
                indicator.presentWindow = UIWindow.shutUpKeyWindow
                indicator.present(haptic: .success, completion: nil)
            }
        }
    }

    private func followTerminalDirectory() {
        guard let report = directories.latest[context.machine.id], report.serial != followedSerial else { return }
        followedSerial = report.serial
        if remotePane.browser.machine?.id == context.machine.id {
            remotePane.browser.open(report.path, syncTerminal: false)
        }
    }

    private func startTransfer(
        sources: [String],
        from: RDMachine?,
        to: RDMachine?,
        destination: String,
        targetEntries: [FileEntry],
        onDone: @escaping () -> Void
    ) {
        guard !sources.isEmpty else { return }
        let existing = Set(targetEntries.map(\.name))
        let conflicts = sources
            .map { ($0 as NSString).lastPathComponent }
            .filter { existing.contains($0) }
        let pending = PendingTransfer(
            sources: sources,
            from: from,
            to: to,
            destination: destination,
            conflictNames: conflicts,
            onDone: onDone
        )
        if conflicts.isEmpty {
            enqueueTransfer(pending, collision: .replace)
        } else {
            pendingCollision = pending
        }
    }

    private func enqueueTransfer(_ pending: PendingTransfer, collision: TransferJob.Collision) {
        if pending.from == nil, pending.to == nil {
            let sources = pending.sources
            let destination = pending.destination
            let onDone = pending.onDone
            Task {
                do {
                    try await Task.detached {
                        try TransferPlacement.copyLocally(sources, into: destination, collision)
                    }.value
                    onDone()
                } catch {
                    UIBridge.presentError(with: error.localizedDescription)
                }
            }
            return
        }
        let direction: TransferJob.Direction
        if pending.from == nil {
            direction = .upload
        } else if pending.to == nil {
            direction = .download
        } else {
            direction = .relay
        }
        let fromRemote = [localPane.browser, remotePane.browser].compactMap { $0 as? RemoteBrowser }.first { $0.server.id == pending.from?.id }
        let toRemote = [localPane.browser, remotePane.browser].compactMap { $0 as? RemoteBrowser }.first { $0.server.id == pending.to?.id }
        let job = TransferJob(
            direction: direction,
            sources: pending.sources,
            from: pending.from,
            to: pending.to,
            destination: pending.destination,
            collision: collision,
            useSudoFrom: fromRemote?.isSudoActive ?? false,
            sudoPasswordFrom: fromRemote?.activeSudoPassword,
            useSudoTo: toRemote?.isSudoActive ?? false,
            sudoPasswordTo: toRemote?.activeSudoPassword
        )
        TransferQueue.shared.enqueue(job)
        pending.onDone()
    }
}

// MARK: - Single Browser Pane

private struct MobileBrowserPane: View {
    @ObservedObject var model: MobileFilePaneModel
    @ObservedObject var peer: MobileFilePaneModel
    let context: FileTransferContext
    let onEdit: (String) -> Void
    let onTransfer: ([String], RDMachine?, RDMachine?, String, [FileEntry], @escaping () -> Void) -> Void

    var body: some View {
        MobileBrowserContent(
            model: model,
            peer: peer,
            browser: model.browser,
            context: context,
            onEdit: onEdit,
            onTransfer: onTransfer
        )
        .id(model.browser.id)
    }
}

private struct MobileBrowserContent: View {
    @ObservedObject var model: MobileFilePaneModel
    @ObservedObject var peer: MobileFilePaneModel
    @ObservedObject var browser: FileBrowser
    let context: FileTransferContext
    @ObservedObject private var store = TamioStore.shared
    @AppStorage(FilesPreference.showsHiddenKey) private var showsHidden = false

    let onEdit: (String) -> Void
    let onTransfer: ([String], RDMachine?, RDMachine?, String, [FileEntry], @escaping () -> Void) -> Void

    @State private var openFilePicker = false
    @State private var showsSudoAlert = false
    @State private var sudoPasswordInput = ""

    private var visibleEntries: [FileEntry] {
        model.entries(browser.entries, showsHidden: showsHidden)
    }

    private var remoteBrowser: RemoteBrowser? { browser as? RemoteBrowser }

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Hairline()
            pathBar
            Hairline()
            content
        }
        .sheet(isPresented: $openFilePicker) {
            FilePickerUIRepresentable(types: [.item], allowMultiple: true) { urls in
                let paths = urls.map(\.path)
                onTransfer(paths, nil, browser.machine, browser.path, browser.entries) {
                    browser.reload()
                }
            }
        }
        .alert("Use sudo for remote files", isPresented: $showsSudoAlert) {
            SecureField("Sudo password (optional)", text: $sudoPasswordInput)
            Button("Enable sudo") {
                guard let remote = remoteBrowser else { return }
                let pw = sudoPasswordInput
                sudoPasswordInput = ""
                Task {
                    let passwordArg = pw.isEmpty ? nil : pw
                    if let err = await remote.enableSudo(password: passwordArg) {
                        UIBridge.presentError(with: err.message)
                    } else if remote.server.id == context.machine.id {
                        _ = await context.enableSudo(password: passwordArg)
                    }
                }
            }
            Button("Cancel", role: .cancel) { sudoPasswordInput = "" }
        } message: {
            Text("Elevates SFTP browsing, transfers, and editing for this session only. Your SSH terminal is not elevated and the password is never saved.")
        }
    }

    private var paneHeader: some View {
        HStack(spacing: RX.Space.s2) {
            Menu {
                Button {
                    model.switchTo(LocalBrowser())
                } label: {
                    Label("Local (Documents)", rx: "folder")
                }
                if !store.machineGroup.machines.isEmpty {
                    Divider()
                    ForEach(store.machineGroup.machines) { machine in
                        Button {
                            model.switchTo(RemoteBrowser(machine: machine))
                        } label: {
                            Label(machine.name, rx: "server.rack")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(rx: browser.machine == nil ? "folder" : "server.rack")
                        .foregroundStyle(.rxAccent)
                    Text(browser.title)
                        .font(.rxSectionTitle)
                        .foregroundStyle(.rxInk)
                    Image(rx: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.rxInkTertiary)
                }
            }

            Spacer(minLength: 4)

            if let remote = remoteBrowser {
                Button {
                    if remote.isSudoActive {
                        Task {
                            await remote.disableSudo()
                            if remote.server.id == context.machine.id {
                                await context.disableSudo()
                            }
                        }
                    } else {
                        sudoPasswordInput = ""
                        showsSudoAlert = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: remote.isSudoActive ? "lock.open.fill" : "shield")
                            .font(.system(size: 10, weight: .semibold))
                        Text("sudo")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(remote.isSudoActive ? Color.orange : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(remote.isSudoActive ? Color.orange.opacity(0.16) : Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }

            if browser.isLoading || (remoteBrowser?.connecting ?? false) {
                ProgressView()
                    .controlSize(.small)
            }

            Button { openFilePicker = true } label: {
                Image(systemName: "arrow.up.doc")
            }
            .buttonStyle(.rx(.plain, iconOnly: true))
            .help(String(localized: "Upload from Files"))

            Button { askNewFolder() } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.rx(.plain, iconOnly: true))
            .help(String(localized: "New Folder"))

            Button { browser.reload() } label: {
                Image(rx: "arrow.clockwise")
            }
            .buttonStyle(.rx(.plain, iconOnly: true))
            .help(String(localized: "Refresh"))

            Menu {
                Toggle("Show Hidden Files", isOn: $showsHidden)
                Divider()
                Picker("Sort by", selection: $model.sort) {
                    ForEach(MobileFilePaneModel.SortColumn.allCases, id: \.self) { column in
                        Text(column.localizedTitle).tag(column)
                    }
                }
                Button {
                    model.ascending.toggle()
                } label: {
                    Label(model.ascending ? String(localized: "Ascending") : String(localized: "Descending"), rx: model.ascending ? "arrow.up" : "arrow.down")
                }
                Divider()
                Button { askGoToPath() } label: {
                    Label("Go to Folder…", rx: "arrow.right")
                }
            } label: {
                Image(rx: "ellipsis")
            }
            .buttonStyle(.rx(.plain, iconOnly: true))
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: 44)
    }

    private var pathBar: some View {
        HStack(spacing: RX.Space.s2) {
            Button { browser.goBack() } label: {
                Image(rx: "chevron.left")
            }
            .disabled(browser.back.isEmpty)
            .buttonStyle(.rx(.plain, size: .small, iconOnly: true))

            Button { browser.goUp() } label: {
                Image(rx: "arrow.up")
            }
            .disabled(browser.path == "/")
            .buttonStyle(.rx(.plain, size: .small, iconOnly: true))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let components = pathComponents
                    ForEach(Array(components.enumerated()), id: \.offset) { index, item in
                        Button {
                            browser.open(item.path)
                        } label: {
                            Text(item.label)
                                .font(.system(size: 12, weight: index == components.count - 1 ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(index == components.count - 1 ? Color.rxInk : Color.rxInkSecondary)
                        }
                        .buttonStyle(.plain)
                        if index != components.count - 1 {
                            Image(rx: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.rxInkTertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: 36)
    }

    private var pathComponents: [(label: String, path: String)] {
        let url = URL(fileURLWithPath: browser.path)
        let parts = url.pathComponents
        var result: [(String, String)] = []
        var running = ""
        for (idx, part) in parts.enumerated() {
            if idx == 0 {
                running = "/"
                result.append(("/", "/"))
            } else {
                running = (running as NSString).appendingPathComponent(part)
                result.append((part, running))
            }
        }
        return result.isEmpty ? [("/", "/")] : result
    }

    @ViewBuilder private var content: some View {
        if let error = browser.error {
            EmptyStateView(
                "Could not open folder",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Retry"
            ) {
                browser.reload()
            }
            .padding(RX.Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleEntries.isEmpty, !browser.isLoading {
            EmptyStateView(
                model.filter.isEmpty ? String(localized: "Empty folder") : String(localized: "No matches"),
                systemImage: model.filter.isEmpty ? "folder" : "magnifyingglass"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: RX.Space.s2) {
                    Image(rx: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.rxInkTertiary)
                    TextField("Filter files", text: $model.filter)
                        .font(.rxBody)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    if !model.filter.isEmpty {
                        Button { model.filter = "" } label: {
                            Image(rx: "xmark.circle.fill")
                                .foregroundStyle(.rxInkTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, RX.Space.s3)
                .padding(.vertical, 6)
                .background(Color.rxSurfaceSunken.opacity(0.6))

                List {
                    ForEach(visibleEntries) { entry in
                        MobileFileRow(
                            entry: entry,
                            browser: browser,
                            peer: peer.browser,
                            onOpenFolder: { browser.open(entry.path) },
                            onEdit: { onEdit(entry.path) },
                            onCopyToPeer: {
                                onTransfer([entry.path], browser.machine, peer.browser.machine, peer.browser.path, peer.browser.entries) {
                                    peer.browser.reload()
                                }
                            },
                            onRename: { askRename(entry) },
                            onDelete: { askDelete(entry) }
                        )
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { browser.reload() }
            }
        }
    }

    private func askNewFolder() {
        UIBridge.askForInputText(
            title: String(localized: "New Folder"),
            message: "",
            placeholder: String(localized: "Folder Name"),
            payload: "",
            canCancel: true
        ) { name in
            guard name.isValidAsFilename else {
                UIBridge.presentError(with: String(localized: "Invalid folder name."))
                return
            }
            Task {
                if let error = await browser.makeFolder(named: name) {
                    UIBridge.presentError(with: error.message)
                }
            }
        }
    }

    private func askGoToPath() {
        UIBridge.askForInputText(
            title: String(localized: "Go to Folder"),
            message: "",
            placeholder: "/path/to/folder",
            payload: browser.path,
            canCancel: true
        ) { path in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else {
                UIBridge.presentError(with: String(localized: "Path must start with /."))
                return
            }
            browser.open(trimmed)
        }
    }

    private func askRename(_ entry: FileEntry) {
        UIBridge.askForInputText(
            title: String(localized: "Rename"),
            message: "",
            placeholder: entry.name,
            payload: entry.name,
            canCancel: true
        ) { next in
            guard next.isValidAsFilename else {
                UIBridge.presentError(with: String(localized: "Invalid filename."))
                return
            }
            Task {
                if let error = await browser.rename(entry, to: next) {
                    UIBridge.presentError(with: error.message)
                }
            }
        }
    }

    private func askDelete(_ entry: FileEntry) {
        UIBridge.requiresConfirmation(
            message: String(localized: "Delete \(entry.name)?"),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            Task {
                if let error = await browser.delete([entry]) {
                    UIBridge.presentError(with: error.message)
                }
            }
        }
    }
}

private struct MobileFileRow: View {
    let entry: FileEntry
    let browser: FileBrowser
    let peer: FileBrowser
    let onOpenFolder: () -> Void
    let onEdit: () -> Void
    let onCopyToPeer: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    private var tooLargeToEdit: Bool {
        (entry.size ?? 0) > FileTransferContext.editableSizeLimit
    }

    private var transferLabel: String {
        if browser.machine == nil, let target = peer.machine {
            return String(localized: "Upload to \(target.name)")
        }
        if browser.machine != nil, peer.machine == nil {
            return String(localized: "Download to Device")
        }
        if let target = peer.machine {
            return String(localized: "Copy to \(target.name)")
        }
        return String(localized: "Copy to Other Pane")
    }

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            Image(rx: iconName)
                .foregroundStyle(entry.isDirectory ? Color.rxAccent : Color.rxInkSecondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.rxInkSecondary)
            }

            Spacer(minLength: 4)

            Menu {
                if entry.isDirectory {
                    Button(action: onOpenFolder) {
                        Label("Open", rx: "arrow.right")
                    }
                } else if browser.machine != nil {
                    Button(action: onEdit) {
                        Label(tooLargeToEdit ? String(localized: "Too Large to Edit") : String(localized: "Edit"), rx: "pencil")
                    }
                    .disabled(tooLargeToEdit)
                }
                Button(action: onCopyToPeer) {
                    Label(transferLabel, systemImage: browser.machine == nil ? "arrow.up.circle" : "arrow.down.circle")
                }
                Divider()
                Button(action: onRename) {
                    Label("Rename…", rx: "pencil")
                }
                Button {
                    UIBridge.sendPasteboard(str: entry.path)
                } label: {
                    Label("Copy Path", rx: "doc.on.clipboard")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete…", rx: "trash")
                }
            } label: {
                Image(rx: "ellipsis")
                    .foregroundStyle(.rxInkSecondary)
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDirectory {
                onOpenFolder()
            } else if browser.machine != nil, !tooLargeToEdit {
                onEdit()
            }
        }
    }

    private var iconName: String {
        if entry.isDirectory { return "folder" }
        if entry.isLink { return "link" }
        switch entry.kind {
        case "image": return "photo"
        case "archive": return "doc.zipper"
        case "video": return "film"
        case "script", "json", "yml", "yaml", "toml", "md", "txt", "log": return "doc.text"
        default: return "doc"
        }
    }

    private var subtitle: String {
        if entry.isDirectory { return entry.permissions }
        let sizeText = entry.size.map { RXFormat.bytesString(Double($0)) } ?? "—"
        return "\(sizeText) · \(entry.permissions)"
    }
}

// MARK: - Transfer Queue Bar & Sheet

private struct TransferBarStrip: View {
    @ObservedObject private var queue = TransferQueue.shared
    @Binding var showsSheet: Bool

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            Button {
                showsSheet = true
            } label: {
                HStack(spacing: RX.Space.s3) {
                    if queue.active.isEmpty {
                        Image(rx: "checkmark.circle.fill")
                            .foregroundStyle(.rxSuccess)
                        Text("\(queue.jobs.count) transfer\(queue.jobs.count == 1 ? "" : "s") finished")
                            .font(.rxBody)
                            .foregroundStyle(.rxInk)
                    } else {
                        ProgressView(value: queue.overallFraction)
                            .frame(width: 80)
                            .tint(.rxAccent)
                        Text(queue.active.first?.title ?? String(localized: "Transferring…"))
                            .font(.rxBody)
                            .foregroundStyle(.rxInk)
                        if queue.active.count > 1 {
                            Text("+\(queue.active.count - 1)")
                                .font(.rxCaption)
                                .foregroundStyle(.rxInkSecondary)
                        }
                    }
                    Spacer()
                    Image(rx: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.rxInkSecondary)
                }
                .padding(.horizontal, RX.Space.s4)
                .frame(height: 44)
                .background(.ultraThinMaterial)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct TransferQueueSheet: View {
    @ObservedObject private var queue = TransferQueue.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if queue.jobs.isEmpty {
                EmptyStateView(
                    "No transfers yet",
                    systemImage: "arrow.up.arrow.down",
                    message: "Uploads, downloads, and server-to-server copies appear here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RXBackdrop().ignoresSafeArea())
            } else {
                List {
                    ForEach(queue.jobs) { job in
                        TransferJobRow(job: job)
                    }
                }
                .rxGroupedList()
            }
        }
        .navigationTitle("Transfers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Clear Finished") {
                    queue.clearFinished()
                }
                .disabled(queue.jobs.allSatisfy { $0.state == .running || $0.state == .queued })
            }
        }
    }
}

private struct TransferJobRow: View {
    @ObservedObject var job: TransferJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.title)
                    .font(.rxBody.weight(.medium))
                    .foregroundStyle(.rxInk)
                Spacer()
                statusBadge
            }

            if job.state == .running {
                ProgressView(value: job.fraction)
                    .tint(.rxAccent)
                HStack {
                    Text(job.currentFile.isEmpty ? String(localized: "Working…") : job.currentFile)
                        .font(.rxCaption)
                        .foregroundStyle(.rxInkSecondary)
                    Spacer()
                    if job.bytesPerSecond > 0 {
                        Text(RXFormat.rateString(Double(job.bytesPerSecond)))
                            .font(.rxCaption.monospacedDigit())
                            .foregroundStyle(.rxInkSecondary)
                    }
                }
            } else if let error = job.error {
                HelpText(error, isError: true)
            }

            HStack(spacing: RX.Space.s2) {
                Spacer()
                if job.state == .running || job.state == .queued {
                    Button("Cancel", role: .destructive) {
                        TransferQueue.shared.cancel(job)
                    }
                    .buttonStyle(.rx(size: .small))
                } else if job.state == .failed || job.state == .cancelled {
                    Button("Retry") {
                        TransferQueue.shared.retry(job)
                    }
                    .buttonStyle(.rx(size: .small))
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusBadge: some View {
        switch job.state {
        case .queued:
            Text("Queued").font(.rxCaption).foregroundStyle(.rxInkSecondary)
        case .running:
            Text("\(Int((job.fraction * 100).rounded()))%").font(.rxCaption.monospacedDigit()).foregroundStyle(.rxAccent)
        case .done:
            Label("Done", rx: "checkmark.circle.fill").font(.rxCaption).foregroundStyle(.rxSuccess)
        case .failed:
            Label("Failed", rx: "exclamationmark.triangle.fill").font(.rxCaption).foregroundStyle(.rxDanger)
        case .cancelled:
            Text("Cancelled").font(.rxCaption).foregroundStyle(.rxInkSecondary)
        }
    }
}

// MARK: - Modal Presentation & Handler Bridge

extension FileTransferContext {
    struct DefaultPresent: View {
        let context: FileTransferContext

        var body: some View {
            DefaultModalPresenter {
                FileTransferView(context: context)
            }
        }
    }
}

/// Bridges TamioModule's shared file-transfer core to UIKit UI.
final class IOSFileTransferUIHandler: FileTransferUIHandler {
    func presentError(_ message: String) {
        MainActor.assumeIsolated { UIBridge.presentError(with: message) }
    }

    func requiresConfirmation(_ message: String, completion: @escaping (Bool) -> Void) {
        nonisolated(unsafe) let completion = completion
        MainActor.assumeIsolated { UIBridge.requiresConfirmation(message: message, confirmation: completion) }
    }

    func autoOpenInterface(_ context: FileTransferContext) {
        nonisolated(unsafe) let context = context
        MainActor.assumeIsolated { present(context) }
    }

    @MainActor private func present(_ context: FileTransferContext) {
        let host = UIHostingController(
            rootView: FileTransferContext.DefaultPresent(context: context)
        )
        host.modalTransitionStyle = .coverVertical
        host.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .phone ? .fullScreen : .formSheet
        host.preferredContentSize = CGSize(width: 920, height: 680)
        PresentationQueue.present(next: host)
    }

    func downloadCompleted() {
        let indicator = SPIndicatorView(
            title: String(localized: "Download Completed"),
            message: String(localized: "Saved to Files"),
            preset: .done
        )
        indicator.presentWindow = UIWindow.shutUpKeyWindow
        indicator.present(haptic: .success, completion: nil)
    }
}
