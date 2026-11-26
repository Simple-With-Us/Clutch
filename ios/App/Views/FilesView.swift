import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The file names that read as code, so the preview shows them the way a
/// person expects to read them.
private let codeExtensions: [String] = [
    "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rs", "go", "rb",
    "java", "kt", "c", "h", "cpp", "hpp", "sh", "bash", "zsh", "json", "yml",
    "yaml", "toml", "xml", "html", "css", "scss", "sql", "pl", "lua", "php",
    "ex", "exs", "erl", "hs", "scala", "dart", "vue", "svelte",
]

/// The files of the folder a thread works in, and one of them to look at.
///
/// The web canvas shows both: the files beside the thread list, and the
/// document the owner picked.  The native apps ask the sidecar for the same
/// two things, so the answer is the same for every engine and the phone and
/// the Mac read the same tree.
public struct FilesView: View {
    let host: ClutchHost
    /// The folder the tree is rooted at.
    ///
    /// Empty asks for the folder a new thread would work in, which is what
    /// the sidecar uses when the client does not name one.
    let root: String

    public init(host: ClutchHost, root: String = "") {
        self.host = host
        self.root = root
    }

    public var body: some View {
        NavigationStack {
            FolderView(host: host, root: root, path: "")
                .navigationTitle("Files")
        }
    }
}

/// One folder in the tree.
struct FolderView: View {
    let host: ClutchHost
    let root: String
    let path: String

    @State private var model: FolderModel

    init(host: ClutchHost, root: String, path: String) {
        self.host = host
        self.root = root
        self.path = path
        _model = State(initialValue: FolderModel(host: host, root: root, path: path))
    }

    var body: some View {
        List {
            if let parent = model.listing?.parent {
                NavigationLink {
                    FolderView(host: host, root: root, path: parent)
                } label: {
                    Label("Up", systemImage: "arrow.uturn.backward")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.listing?.entries ?? []) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        FolderView(host: host, root: root, path: entry.path)
                    } label: {
                        row(for: entry)
                    }
                } else {
                    NavigationLink {
                        FilePreviewView(host: host, root: root, path: entry.path, name: entry.name)
                    } label: {
                        row(for: entry)
                    }
                }
            }
        }
        .listStyle(.plain)
        .task { await model.load() }
        .overlay {
            switch model.phase {
            case .loading:
                ProgressView()
            case .failed(let reason):
                ContentUnavailableView(
                    "Cannot Read the Folder",
                    systemImage: "folder.badge.questionmark",
                    description: Text(reason)
                )
            case .idle, .ready:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func row(for entry: FilesClient.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let size = entry.size, !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Pick one folder: the New Thread sheet's "Browse…" destination, so a
/// thread can be pointed at the repo it should work in before its first
/// turn exists.
struct FolderPickerView: View {
    let host: ClutchHost
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: FolderModel
    @State private var path: String
    /// The tree the picker browses, editable so a folder outside the
    /// sidecar's home directory — `/mnt` on a server — is reachable.
    @State private var root: String
    @State private var rootDraft = ""
    @State private var showRootEditor = false

    init(host: ClutchHost, root: String, onChoose: @escaping (String) -> Void) {
        self.host = host
        self.onChoose = onChoose
        _model = State(initialValue: FolderModel(host: host, root: root, path: ""))
        _path = State(initialValue: "")
        _root = State(initialValue: root)
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    rootDraft = root
                    showRootEditor = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Browse From")
                                .font(ClutchFont.microStrong)
                                .foregroundStyle(.secondary)
                            Text(rootLabel)
                                .font(ClutchFont.captionStrong)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "pencil")
                            .font(ClutchFont.micro)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Browse From \(rootLabel)")
                if let parent = model.listing?.parent {
                    Button {
                        navigate(to: parent)
                    } label: {
                        Label(parent.isEmpty ? "Root" : (parent as NSString).lastPathComponent, systemImage: "arrow.uturn.backward")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.listing?.entries ?? []) { entry in
                    if entry.isDirectory {
                        Button {
                            navigate(to: entry.path)
                        } label: {
                            row(for: entry)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .task { await model.load() }
            .overlay {
                switch model.phase {
                case .loading:
                    ProgressView()
                case .failed(let reason):
                    ContentUnavailableView(
                        "Cannot Read the Folder",
                        systemImage: "folder.badge.questionmark",
                        description: Text(reason)
                    )
                case .idle, .ready:
                    EmptyView()
                }
            }
            .navigationTitle("Choose Folder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose This Folder") {
                        onChoose(chosenPath)
                        dismiss()
                    }
                    .disabled(model.listing == nil)
                }
            }
            .alert("Browse From", isPresented: $showRootEditor) {
                TextField("Root Folder", text: $rootDraft)
#if os(iOS)
                    .autocapitalization(.none)
#endif
                    .autocorrectionDisabled()
                Button("Browse") { useTypedRoot() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Empty browses the sidecar's home directory. Type a folder like /mnt/fleet-extra to browse from there instead.")
            }
        }
    }

    private var rootLabel: String {
        root.isEmpty ? "Default (Home Directory)" : root
    }

    /// Re-roots the picker at a typed folder: the sidecar jails browsing to
    /// whatever root the client names, so naming `/mnt` — rather than
    /// climbing to it from home, which the jail refuses — is how a server
    /// path outside home is reached.
    private func useTypedRoot() {
        let trimmed = rootDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != root else { return }
        // Empty means the sidecar's default; anything else must be absolute,
        // because a relative root would resolve against an unknown folder.
        guard trimmed.isEmpty || trimmed.hasPrefix("/") else { return }
        root = trimmed
        path = ""
        model = FolderModel(host: host, root: trimmed, path: "")
        Task { await model.load() }
    }

    private func navigate(to target: String) {
        path = target
        model = FolderModel(host: host, root: root, path: target)
        Task { await model.load() }
    }

    /// The folder on screen, by the path the machine that holds it uses.
    ///
    /// The engine a thread runs in resolves a relative working folder
    /// against its own working directory, so the folder is chosen by the
    /// absolute path the sidecar reports for it.  A sidecar older than
    /// that field reports none, and the relative path is the best answer
    /// there is.
    private var chosenPath: String {
        model.listing?.absolute ?? path
    }

    @ViewBuilder
    private func row(for entry: FilesClient.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(Color.accentColor)
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// One file, shown.
struct FilePreviewView: View {
    let host: ClutchHost
    let root: String
    let path: String
    let name: String

    @State private var model: FilePreviewModel
    @State private var remoteNote: String?

    init(host: ClutchHost, root: String, path: String, name: String) {
        self.host = host
        self.root = root
        self.path = path
        self.name = name
        _model = State(initialValue: FilePreviewModel(host: host, root: root, path: path))
    }

    var body: some View {
        ScrollView {
            if let note = remoteNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(ClutchFont.caption)
                    .foregroundStyle(ClutchColor.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            Text(model.body)
                .font(model.isCode ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                // A readable line length on iPad, the same cap the
                // transcript uses.
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(16)
        }
        .background(Color.clutchBackground)
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
        .overlay {
            switch model.phase {
            case .loading:
                ProgressView()
            case .failed(let reason):
                ContentUnavailableView(
                    "Cannot Read the File",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(reason)
                )
            case .idle, .ready:
                EmptyView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    copyToClipboard(bestKnownPath)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .help("Copy the file's path on the host")
                .disabled(model.preview == nil)
                Button {
                    copyToClipboard(model.body)
                } label: {
                    Label("Copy Contents", systemImage: "doc.on.clipboard")
                }
                .help("Copy the preview text")
                .disabled(model.preview?.isText != true)
                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the file again")
                #if os(macOS)
                Button {
                    openInEditor()
                } label: {
                    Label("Open in Editor", systemImage: "arrow.up.forward.app")
                }
                .help(host.isLocal ? "Open the file in its default editor" : "Download a read-only copy and open it")
                .disabled(model.preview?.isText != true)
                #endif
            }
        }
    }

    /// The file's path as the host knows it: the root joined to the
    /// preview's relative path, or the relative path alone when the tree
    /// was browsed from the sidecar's default.
    private var bestKnownPath: String {
        guard let preview = model.preview else { return path }
        if root.isEmpty { return preview.path }
        return (root as NSString).appendingPathComponent(preview.path)
    }

    private func copyToClipboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    #if os(macOS)
    /// Opens the file in its default editor.  On a local host the sidecar
    /// path names a local file, so it opens directly; on a remote host the
    /// preview downloads to a read-only copy, because the remote file
    /// itself is not on this machine.
    private func openInEditor() {
        guard model.preview?.isText == true else { return }
        if host.isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: localPath))
            return
        }
        do {
            let safeName = (name as NSString).lastPathComponent.isEmpty
                ? "preview.txt" : (name as NSString).lastPathComponent
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("clutch-preview-\(UUID().uuidString)-\(safeName)")
            try model.body.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
            remoteNote = "A read-only copy — edits won't save."
        } catch {
            remoteNote = "The copy could not be downloaded."
        }
    }

    /// The file on this machine's disk: the sidecar path when the tree was
    /// rooted explicitly, or the same path under this user's home when the
    /// tree was browsed from the sidecar's default.
    private var localPath: String {
        if let absolute = model.preview?.absolute, !absolute.isEmpty { return absolute }
        let relative = model.preview?.path ?? path
        if !root.isEmpty { return (root as NSString).appendingPathComponent(relative) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(relative)
    }
    #endif
}

/// What one folder holds.
@MainActor
@Observable
final class FolderModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    var phase: Phase = .idle
    var listing: FilesClient.Listing?

    private let host: ClutchHost
    private let root: String
    private let path: String

    init(host: ClutchHost, root: String, path: String) {
        self.host = host
        self.root = root
        self.path = path
    }

    func load() async {
        guard phase == .idle else { return }
        phase = .loading
        do {
            listing = try await FilesClient(host: host).list(root: root, path: path)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// What one file holds.
@MainActor
@Observable
final class FilePreviewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    var phase: Phase = .idle
    var preview: FilesClient.Preview?

    private let host: ClutchHost
    private let root: String
    private let path: String

    init(host: ClutchHost, root: String, path: String) {
        self.host = host
        self.root = root
        self.path = path
    }

    /// The text on screen, and what it says about the file.
    var body: String {
        guard let preview else { return "" }
        guard preview.isText else {
            return "This file is not text, so there is nothing to show."
        }
        if preview.truncated {
            return preview.content + "\n\n[the file is longer than this preview]"
        }
        return preview.content
    }

    /// Whether the file reads as code.
    ///
    /// A file that is not text is never code, and a file with no name to
    /// judge by is not either.
    var isCode: Bool {
        guard let preview, preview.isText else { return false }
        let name = preview.name.lowercased()
        return codeExtensions.contains { name.hasSuffix(".\($0)") }
    }

    func load() async {
        guard phase == .idle else { return }
        phase = .loading
        do {
            preview = try await FilesClient(host: host).preview(root: root, path: path)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reads the file again, after an edit elsewhere or a failed load.
    func reload() async {
        phase = .idle
        await load()
    }
}
