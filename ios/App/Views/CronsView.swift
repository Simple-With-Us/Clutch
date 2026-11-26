import SwiftUI

/// The reminders the host's sessions hold: what will fire, in which
/// thread, and when.  Creating asks the owning thread's engine to make
/// the reminder through the sidecar, and the list the owner reads back
/// is the host's schedule projection, so a row here is a reminder the
/// host really holds.
public struct CronsView: View {
    public var host: ClutchHost
    public var sessions: [AcpSessionInfo]

    @State private var crons: [CronItem] = []
    @State private var phase: Phase = .idle
    @State private var showCreate = false
    @State private var actionError: String?

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public init(host: ClutchHost, sessions: [AcpSessionInfo]) {
        self.host = host
        self.sessions = sessions
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                ProgressView("Loading reminders…")
            case .failed(let message):
                ContentUnavailableView("Reminders Unavailable", systemImage: "clock.badge.exclamationmark", description: Text(message))
            case .ready:
                if crons.isEmpty {
                    ContentUnavailableView("No Reminders", systemImage: "clock", description: Text("Reminders a thread creates for itself will show here."))
                } else {
                    List {
                        ForEach(crons) { cron in
                            VStack(alignment: .leading, spacing: ClutchSpacing.tight) {
                                Text(cron.prompt)
                                    .font(ClutchFont.body)
                                HStack(spacing: ClutchSpacing.tight) {
                                    Text(cron.ruleLabel)
                                    Text("·")
                                    Text(cron.state == "overdue" ? "Overdue" : "Scheduled")
                                        .foregroundStyle(cron.state == "overdue" ? ClutchColor.warning : ClutchColor.textSecondary)
                                }
                                .font(ClutchFont.caption)
                                .foregroundStyle(.secondary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    Task { await delete(cron) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Reminders")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Reminder", systemImage: "plus") { showCreate = true }
                    .disabled(sessions.isEmpty)
            }
        }
        .sheet(isPresented: $showCreate) {
            CronCreateView(host: host, sessions: sessions) {
                Task { await load() }
            }
        }
        .alert("Reminder Action Failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            crons = try await SessionsClient(host: host).crons()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func delete(_ cron: CronItem) async {
        do {
            try await SessionsClient(host: host).deleteCron(sessionId: cron.sessionId, id: cron.cronId)
            crons.removeAll { $0.id == cron.id }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// The create sheet: a thread to own the reminder, what it should say,
/// and when.  Fixed-rate reminders start at five minutes, the floor the
/// schedule service itself enforces.
private struct CronCreateView: View {
    var host: ClutchHost
    var sessions: [AcpSessionInfo]
    var onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sessionId: String = ""
    @State private var prompt = ""
    @State private var ruleKind = "after"
    @State private var minutes = 60
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Thread", selection: $sessionId) {
                    ForEach(sessions) { session in
                        Text(session.displayTitle).tag(session.sessionId)
                    }
                }
                TextField("Reminder", text: $prompt, axis: .vertical)
                Picker("When", selection: $ruleKind) {
                    Text("After").tag("after")
                    Text("Every").tag("every")
                }
                .pickerStyle(.segmented)
                Stepper(value: $minutes, in: ruleKind == "every" ? 5...1440 : 1...1440, step: 5) {
                    Text("\(minutes) minutes")
                }
                if let saveError {
                    Text(saveError)
                        .font(ClutchFont.caption)
                        .foregroundStyle(ClutchColor.danger)
                }
            }
            .navigationTitle("New Reminder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sessionId.isEmpty || saving)
                }
            }
            .onAppear {
                if sessionId.isEmpty { sessionId = sessions.first?.sessionId ?? "" }
            }
        }
    }

    private func create() async {
        saving = true
        saveError = nil
        let seconds = minutes * 60
        let rule: [String: Any] = ruleKind == "every" ? ["everySeconds": seconds] : ["afterSeconds": seconds]
        do {
            _ = try await SessionsClient(host: host).createCron(
                sessionId: sessionId,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                rule: rule
            )
            onCreated()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        saving = false
    }
}
