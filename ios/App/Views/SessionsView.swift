import SwiftUI

/// Native session list for the sidecar's MiniMax Code threads.  This is the
/// piece the phone was missing: the same list the Mac chat sidebar shows,
/// without handing the screen back to the web view.
@MainActor
@Observable
final class SessionsModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded([AcpSessionInfo])
        case failed(String)
    }

    private let host: ClutchHost
    private let client: SessionsClient

    var phase: Phase = .idle

    init(host: ClutchHost) {
        self.host = host
        self.client = SessionsClient(host: host)
    }

    func load() async {
        guard phase != .loading else { return }
        phase = .loading
        do {
            let sessions = try await client.list()
            // Freshest first; the sidecar already sorts, but sessions with an
            // unparseable stamp would otherwise sink to the bottom silently.
            phase = .loaded(sessions.sorted { lhs, rhs in
                switch (lhs.updated, rhs.updated) {
                case let (l?, r?): return l > r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.sessionId < rhs.sessionId
                }
            })
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Pull-to-refresh keeps the old list on screen while reloading, so a slow
    /// sidecar does not blank a thread the user is reading.
    func refresh() async {
        let previous = phase
        if case .loading = previous { return }
        await load()
    }
}

public struct SessionsView: View {
    let host: ClutchHost
    @State private var model: SessionsModel

    public init(host: ClutchHost) {
        self.host = host
        _model = State(initialValue: SessionsModel(host: host))
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sessions")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh Sessions")
                    }
                }
                .task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let sessions) where sessions.isEmpty:
            ContentUnavailableView(
                "No Sessions",
                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                description: Text("MiniMax Code threads appear here once this Mac has run one.")
            )
        case .loaded(let sessions):
            List(sessions) { session in
                NavigationLink {
                    SessionThreadView(host: host, session: session)
                } label: {
                    SessionRow(session: session)
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Sessions", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
            }
        }
    }
}

struct SessionRow: View {
    let session: AcpSessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.displayTitle)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let cwd = session.cwd, !cwd.isEmpty {
                    Label(collapseHome(cwd), systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                if let updated = session.updated {
                    Text(updated, format: .relative(presentation: .named))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    /// `/Users/jay/lanes/foo` reads better as `~/lanes/foo` in a list.
    private func collapseHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
