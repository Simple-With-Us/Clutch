import SwiftUI

/// Projects group links; they do not move threads, attach them, or switch the
/// main workspace's active host. The source host supplies each transcript.
@MainActor
struct ThreadProjectsView: View {
    let hosts: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var store = ThreadProjectStore.shared
    @State private var name = ""
    @State private var creating = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.storageError {
                    Text("Saved projects could not be read.").foregroundStyle(.secondary)
                } else if store.projects.isEmpty {
                    Text("Create a project to group threads from different hosts and coding tools.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.projects) { project in
                    NavigationLink(value: project.id) {
                        Label(project.name, systemImage: "folder")
                    }
                }
            }
            .navigationTitle("Projects")
            .navigationDestination(for: UUID.self) { id in
                ThreadProjectDetail(projectID: id, store: store, hosts: hosts)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        name = ""
                        creating = true
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .accessibilityIdentifier("clutch-projects-create")
                    .disabled(store.storageError)
                }
            }
            .alert("New Project", isPresented: $creating) {
                TextField("Project Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    if let id = store.create(name: name) { path.append(id) }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .safeAreaInset(edge: .bottom) {
                Text("Projects on this device don’t change projects on your hosts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 480)
        #endif
    }
}

@MainActor
private struct ThreadProjectDetail: View {
    let projectID: UUID
    let store: ThreadProjectStore
    let hosts: HostStore
    private var project: ThreadProject? { store.projects.first { $0.id == projectID } }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    List(hosts.hosts) { host in
                        NavigationLink {
                            ProjectThreadPicker(host: host, store: store, projectID: projectID)
                        } label: {
                            Label(host.name, systemImage: "server.rack")
                        }
                        .accessibilityIdentifier("clutch-project-host-\(host.name)")
                    }
                    .navigationTitle("Choose A Host")
                    .overlay {
                        if hosts.hosts.isEmpty {
                            ContentUnavailableView("No Paired Hosts", systemImage: "server.rack")
                        }
                    }
                } label: {
                    Label("Add Threads", systemImage: "plus")
                }
                .accessibilityIdentifier("clutch-project-add-threads")
            }

            Section("Threads") {
                if project?.threads.isEmpty != false {
                    Text("No threads added yet.").foregroundStyle(.secondary)
                }
                ForEach(project?.threads ?? []) { thread in
                    NavigationLink {
                        ProjectThreadDestination(thread: thread, hosts: hosts)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(thread.title)
                            let hostName = thread.pairedHost(in: hosts.hosts)?.name ?? thread.hostName
                            Text("\(hostName) · \(EngineLabels.label(for: thread.id.engineID))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("clutch-project-member-\(thread.id.engineID)-\(thread.id.sessionID)")
                    .contextMenu {
                        Button("Remove From Project", role: .destructive) {
                            store.remove(thread.id, from: projectID)
                        }
                    }
                    #if os(iOS)
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            store.remove(thread.id, from: projectID)
                        }
                    }
                    #endif
                }
            }
        }
        .navigationTitle(project?.name ?? "Project")
    }
}

@MainActor
private struct ProjectThreadPicker: View {
    let host: ClutchHost
    let store: ThreadProjectStore
    let projectID: UUID
    @State private var engines: [String] = []
    @State private var labels: [String: String] = [:]
    @State private var engine = ""
    @State private var sessions: [AcpSessionInfo] = []
    @State private var listEngine: String?
    @State private var status: String?
    @State private var loading = false
    @State private var query = ""
    @State private var limit = 100
    @State private var retry = 0

    private struct Request: Hashable {
        let pairingKey: String
        let engine: String
        let limit: Int
        let retry: Int
    }

    var body: some View {
        let request = Request(pairingKey: host.pairingKey, engine: engine, limit: limit, retry: retry)
        List {
            if !engines.isEmpty {
                Picker("Coding Tool", selection: $engine) {
                    ForEach(engines, id: \.self) { id in
                        Text(labels[id] ?? EngineLabels.label(for: id)).tag(id)
                    }
                }
                .onChange(of: engine) { _, _ in limit = 100 }
            }
            if loading || (engine.isEmpty && status == nil) {
                ProgressView()
            } else if let status {
                Text(status).foregroundStyle(.secondary)
                if !engine.isEmpty { Button("Retry") { retry += 1 } }
            } else if listEngine == engine {
                if sessions.isEmpty {
                    Text("No threads found for this tool.").foregroundStyle(.secondary)
                }
                ForEach(AcpSessionInfo.filtered(sessions, query: query)) { session in
                    let ref = ProjectThread(hostID: host.id, hostName: host.name, engineID: engine, session: session)
                    let added = store.projects.first { $0.id == projectID }?.threads.contains { $0.id == ref.id } == true
                    Button {
                        store.add(ref, to: projectID)
                    } label: {
                        VStack(alignment: .leading) {
                            Label(session.displayTitle, systemImage: added ? "checkmark.circle" : "plus.circle")
                            if let cwd = session.cwd, !cwd.isEmpty {
                                Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("clutch-project-add-\(engine)-\(session.sessionId)")
                    .disabled(added || store.storageError)
                }
                if sessions.count >= limit && limit < 1000 {
                    Button("Load More Threads") { limit += 100 }
                }
            }
        }
        .navigationTitle(host.name)
        .searchable(text: $query, prompt: "Find Threads")
        .task(id: host.pairingKey) { await loadCatalog() }
        .task(id: request) { await load(request) }
    }

    private func loadCatalog() async {
        do {
            let catalog = try await EngineCatalogClient(host: host).fetch()
            guard !Task.isCancelled else { return }
            let choices = catalog.availableEngines.filter(\.supportsThreads)
            var seen = Set<String>()
            engines = choices.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
            for choice in choices { labels[choice.id] = choice.label }
            engine = engines.first ?? ""
            if engine.isEmpty { status = "No coding tools with saved threads are available on this host." }
        } catch {
            guard !Task.isCancelled else { return }
            // Older hosts can list sessions even if they have no catalog.
            engines = host.isMiniMaxCodeOnly ? ["mcode", "muse", "zcode"] : EngineIds.all
            engine = engines.first ?? ""
        }
    }

    private func load(_ request: Request) async {
        guard !request.engine.isEmpty, !Task.isCancelled else { return }
        loading = true
        listEngine = nil
        status = nil
        do {
            let listed = try await SessionsClient(host: host).list(engine: request.engine, limit: request.limit)
            guard !Task.isCancelled, host.pairingKey == request.pairingKey,
                  engine == request.engine, limit == request.limit, retry == request.retry else { return }
            var seen = Set<String>()
            sessions = AcpSessionInfo.newestFirst(listed).filter {
                !$0.sessionId.isEmpty && seen.insert($0.sessionId).inserted
            }
            listEngine = request.engine
            loading = false
        } catch {
            guard !Task.isCancelled, host.pairingKey == request.pairingKey,
                  engine == request.engine, limit == request.limit, retry == request.retry else { return }
            status = "Couldn’t load threads for this tool on this host."
            loading = false
        }
    }
}

@MainActor
private struct ProjectThreadDestination: View {
    let thread: ProjectThread
    let hosts: HostStore

    var body: some View {
        if let host = thread.pairedHost(in: hosts.hosts) {
            ProjectThreadPreview(thread: thread, host: host).id(host.pairingKey)
        } else {
            ContentUnavailableView(
                "Host Not Paired",
                systemImage: "server.rack",
                description: Text("This thread belongs to \(thread.hostName).")
            )
        }
    }
}

@MainActor
private struct ProjectThreadPreview: View {
    let thread: ProjectThread
    let host: ClutchHost
    @State private var preview: SessionsClient.PreviewSession?
    @State private var failed = false

    var body: some View {
        List {
            Section {
                NavigationLink("Resume This Thread") {
                    SessionThreadView(
                        host: host,
                        session: thread.session(usingPreviewCwd: preview?.cwd),
                        engine: thread.id.engineID
                    )
                }
                Text("\(host.name) · \(EngineLabels.label(for: thread.id.engineID))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let preview {
                if preview.truncated {
                    Text("Showing recent messages only.").foregroundStyle(.secondary)
                }
                let messages = preview.history.filter { $0.isVisible && !$0.text.isEmpty }
                if messages.isEmpty {
                    Text("No messages in this preview.").foregroundStyle(.secondary)
                }
                ForEach(Array(messages.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading) {
                        Text(entry.isUser ? "You" : "Assistant").font(.caption).foregroundStyle(.secondary)
                        Text(entry.text).textSelection(.enabled)
                    }
                }
            } else if failed {
                Text("Preview unavailable.").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(thread.title)
        .task {
            do {
                let result = try await SessionsClient(host: host).preview(
                    sessionId: thread.id.sessionID, cwd: thread.cwd, engine: thread.id.engineID
                )
                guard !Task.isCancelled else { return }
                guard result.remoteSessionId == thread.id.sessionID else { failed = true; return }
                preview = result
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}
