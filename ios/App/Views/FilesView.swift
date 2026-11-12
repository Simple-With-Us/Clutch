import SwiftUI

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

/// One file, shown.
struct FilePreviewView: View {
    let host: ClutchHost
    let root: String
    let path: String
    let name: String

    @State private var model: FilePreviewModel

    init(host: ClutchHost, root: String, path: String, name: String) {
        self.host = host
        self.root = root
        self.path = path
        self.name = name
        _model = State(initialValue: FilePreviewModel(host: host, root: root, path: path))
    }

    var body: some View {
        ScrollView {
            Text(model.body)
                .font(model.isCode ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
    }
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
}
