import SwiftUI
import Foundation

#if os(macOS)
import AppKit
#endif

/// What a right-click on a thread row can do.
///
/// Modelled as one enum rather than a dozen callbacks so the sidebar stays a
/// dumb surface:  it reports intent, and `ChatViewMac` decides what actually
/// happens.  Every case here is real —  the ones the sidecar cannot yet do are
/// absent rather than shown and silently ignored.
public enum ThreadSidebarAction {
    /// Copy the engine's session id to the pasteboard.
    case copySessionId(AcpSessionInfo)
    /// Move a thread into a Project, or out of all of them when `nil`.
    case assignProject(AcpSessionInfo, String?)
    /// Create a Project with this name and assign the thread to it.
    case createProject(String, AcpSessionInfo)
    /// Archive or restore a thread.  Archiving hides it and is reversible.
    case setArchived(AcpSessionInfo, Bool)
    /// Open the thread's working directory in Finder.
    case revealInFinder(AcpSessionInfo)
}

/// The thread rail, shared by the Mac chat surface and the iPhone/iPad
/// dashboard so both platforms show one thread list.
///
/// On macOS this is a drag-resizable rail beside the transcript.  On iOS it is
/// the sidebar column of a `NavigationSplitView`, where the system sizes the
/// column and a tap pushes the thread instead of swapping the pane — so
/// `fixedWidth` is nil there and every macOS affordance below is compiled out.
///
/// The error banner is rendered above the list rather than in a branch the
/// loaded-list state can shadow.  That is deliberate: a failed resume used to
/// be assigned to a branch that was unreachable once the list had loaded, so
/// tapping a thread looked like it did nothing at all.
struct ThreadSidebar: View {
    /// Thread list as handed over; this view sorts it newest-first itself
    /// (see `ordered`), so the caller may pass the sidecar's raw order.
    var sessions: [AcpSessionInfo]
    var selectedId: String?
    var loading: Bool
    var loadingId: String?
    var errorText: String?
    /// Projects offered in the row's context menu.  Empty means the menu shows
    /// only the create-project affordance.
    var projects: [SessionsClient.Project] = []
    var onSelect: (AcpSessionInfo) -> Void
    var onNew: () -> Void
    var onRefresh: () -> Void
    var onAction: (ThreadSidebarAction, AcpSessionInfo) -> Void = { _, _ in }
    /// Whether archived threads are listed (marked, restorable) or hidden.
    var showArchived: Bool = false
    /// Flip `showArchived` and reload.  Without this, archiving a thread made
    /// it unreachable: every list call excluded archived rows, so the restore
    /// action could never be reached.
    var onToggleArchived: (() -> Void)? = nil
    /// macOS pins the rail width; a split view lets the system choose, so iOS
    /// passes nil and lets the column breathe.
    var fixedWidth: CGFloat? = 232
    /// Called continuously while the user drags the divider.  nil on iOS.
    var onResize: ((CGFloat) -> Void)? = nil
    /// Called once when the drag ends, with the final width.  Persisting
    /// belongs here, not in `onResize`, so UserDefaults is written once per
    /// drag instead of once per frame.
    var onResizeEnd: ((CGFloat) -> Void)? = nil
    /// Width the current drag started from; translation-based resizing needs
    /// it because the gesture's `location` is in the 5pt handle's own
    /// coordinate space, not the rail's.
    @State private var dragStartWidth: CGFloat?

    /// Drag the rail no narrower than this or wider than the chat can spare.
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 460

    #if os(macOS)
    /// Ask for a Project name from a context menu.
    ///
    /// A menu cannot host a text field, so this uses the platform's own
    /// sheet-style prompt.  It runs a modal alert only while the user has
    /// deliberately clicked "New Project…"; nothing here fires on its own.
    static func promptForProjectName() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Project"
        alert.informativeText = "Threads you assign to it are grouped together."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Project Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    #endif

    @State private var query: String = ""
    @State private var hoveredId: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchBar
                header
                Divider()

                if let errorText, !errorText.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorText)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Retry", action: onRefresh)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12))
                    Divider()
                }

                if visible.isEmpty && loading {
                    ProgressView("Loading Threads…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visible.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: query.isEmpty ? "text.bubble" : "magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text(query.isEmpty ? "No Threads Yet" : "No Matches")
                            .font(.system(size: 12, weight: .semibold))
                        Text(query.isEmpty ? "Start One With The Button Above." : "Try A Different Search.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(visible) { session in
                                row(session)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(width: fixedWidth)
            .frame(maxHeight: .infinity)
            .background(Color.clutchBackground)

            #if os(macOS)
            if onResize != nil {
                resizeHandle
            }
            #endif
        }
    }

    /// The search field sits above the New/Threads row at the top-left, where a
    /// user looks first when they know part of a name but not the whole thing.
    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Search Threads", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 8)
        .padding(.top, 8)
        #if os(macOS)
        .help("Search Threads By Name, Folder, ID Or Model")
        #endif
    }

    #if os(macOS)
    /// A 5pt grab strip on the rail's trailing edge.  `col-resize` is the
    /// platform's own cursor for this, and a plain Rectangle is enough for
    /// AppKit to turn dragging into a resize.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { inside in
                #if os(macOS)
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                #endif
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = fixedWidth }
                        let base = dragStartWidth ?? fixedWidth ?? Self.minWidth
                        let next = min(max(base + value.translation.width, Self.minWidth), Self.maxWidth)
                        onResize?(next)
                    }
                    .onEnded { value in
                        let base = dragStartWidth ?? fixedWidth ?? Self.minWidth
                        let final = min(max(base + value.translation.width, Self.minWidth), Self.maxWidth)
                        onResize?(final)
                        onResizeEnd?(final)
                        dragStartWidth = nil
                    }
            )
            .accessibilityLabel("Resize Sidebar")
    }
    #endif

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onNew) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Thread")
            #if os(macOS)
            .help("New Thread")
            #endif

            Text("Threads")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if let onToggleArchived {
                Button(action: onToggleArchived) {
                    Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(showArchived ? Color.accentColor : .secondary)
                .accessibilityLabel(showArchived ? "Hide Archived Threads" : "Show Archived Threads")
                #if os(macOS)
                .help(showArchived ? "Hide Archived Threads" : "Show Archived Threads")
                #endif
            }

            if loading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            } else {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Refresh Threads")
                #if os(macOS)
                .help("Refresh Threads")
                #endif
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func row(_ session: AcpSessionInfo) -> some View {
        ThreadSidebarRow(
            session: session,
            isSelected: session.sessionId == selectedId,
            isLoading: loadingId == session.sessionId,
            isDisabled: loadingId != nil && loadingId != session.sessionId,
            projects: projects,
            onSelect: onSelect,
            onAction: onAction
        )
        #if os(macOS)
        .onHover { inside in
            hoveredId = inside ? session.sessionId : (hoveredId == session.sessionId ? nil : hoveredId)
        }
        .popover(isPresented: Binding(
            get: { hoveredId == session.sessionId },
            set: { if !$0 && hoveredId == session.sessionId { hoveredId = nil } }
        ), arrowEdge: .trailing) {
            ThreadDetailsCard(session: session, projects: projects)
        }
        .help("")
        #endif
    }

    /// Newest first, then filtered by the search field.  A blank query matches
    /// everything, so clearing the field always restores the full list.
    private var ordered: [AcpSessionInfo] {
        AcpSessionInfo.newestFirst(sessions)
    }

    private var visible: [AcpSessionInfo] {
        ordered.filter { $0.matchesSearch(query) }
    }
}

/// One thread row, shared by the macOS rail and the iOS/iPad sidebar list so
/// a thread looks and reads identically on every platform.
///
/// `List` already draws a selection highlight and a disclosure indicator on
/// iOS, so the row only paints its own highlight when asked to (`isSelected`).
struct ThreadSidebarRow: View {
    let session: AcpSessionInfo
    var isSelected: Bool
    var isLoading: Bool
    var isDisabled: Bool
    var projects: [SessionsClient.Project] = []
    var onSelect: (AcpSessionInfo) -> Void
    var onAction: (ThreadSidebarAction, AcpSessionInfo) -> Void = { _, _ in }

    var body: some View {
        Button {
            onSelect(session)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let cwd = session.cwd, !cwd.isEmpty {
                            Text(cwd)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        if let when = session.updated {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(when, style: .relative)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // The one usage fact cheap enough to show inline on every
                    // row.  Absent rather than estimated when the engine has not
                    // reported a window.
                    if let occupancy = session.usage?.occupancyLabel {
                        Text(occupancy)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        // VoiceOver needs the thread named, not just its working directory.
        .accessibilityLabel("Thread, \(session.displayTitle)")
        #if os(macOS)
        .contextMenu { menu }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var menu: some View {
        Button("Copy Session ID") {
            onAction(.copySessionId(session), session)
        }

        if let cwd = session.cwd, !cwd.isEmpty {
            Button("Reveal Working Folder In Finder") {
                onAction(.revealInFinder(session), session)
            }
        }

        Divider()

        Menu("Assign To Project") {
            Button("None") {
                onAction(.assignProject(session, nil), session)
            }
            Divider()
            ForEach(projects) { project in
                // The tick marks where this thread currently sits.
                let current = project.id == session.projectId
                Button {
                    onAction(.assignProject(session, current ? nil : project.id), session)
                } label: {
                    if current {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
            Divider()
            Button("New Project…") {
                guard let name = ThreadSidebar.promptForProjectName() else { return }
                onAction(.createProject(name, session), session)
            }
        }

        Divider()

        if session.archived == true {
            Button("Restore From Archive") {
                onAction(.setArchived(session, false), session)
            }
        } else {
            Button("Archive") {
                onAction(.setArchived(session, true), session)
            }
        }
    }
    #endif
}

/// The hover card.  Shows only what the sidecar actually knows;  a fact the
/// engine did not report reads "Not reported" instead of showing a zero or an
/// invented estimate.
struct ThreadDetailsCard: View {
    let session: AcpSessionInfo
    var projects: [SessionsClient.Project] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)

            Divider()

            detail("Session ID", session.sessionId, monospaced: true)
            detail("Folder", session.cwd ?? "Not reported", monospaced: true)
            detail("Model", session.usage?.model ?? "Not reported")
            detail("Provider", session.usage?.provider ?? "Not reported")

            if let usage = session.usage {
                Divider()
                detail(
                    "Context Used",
                    usage.occupancyLabel ?? "Not reported",
                    monospaced: true
                )
                detail(
                    "Output Rate",
                    usage.rateLabel ?? "Not enough data yet",
                    monospaced: true
                )
                if let cache = usage.cacheReadTokens {
                    detail("Cached Input", AcpSessionUsage.compact(cache), monospaced: true)
                }
            } else {
                Divider()
                Text("The engine has not reported usage for this thread.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let projectId = session.projectId,
               let name = projects.first(where: { $0.id == projectId })?.name {
                Divider()
                detail("Project", name)
            }

            if session.archived == true {
                detail("Archived", "Yes")
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(monospaced ? .system(size: 10, design: .monospaced) : .system(size: 10))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

extension AcpSessionInfo {
    /// Case-insensitive substring match across everything a row can show, so a
    /// user can search by thread name, folder, the raw session id, or the model
    /// driving it.  An empty query matches everything.
    func matchesSearch(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty { return true }
        var haystacks = [displayTitle.lowercased(), sessionId.lowercased()]
        if let cwd, !cwd.isEmpty { haystacks.append(cwd.lowercased()) }
        if let model = usage?.model { haystacks.append(model.lowercased()) }
        if let provider = usage?.provider { haystacks.append(provider.lowercased()) }
        if let projectId { haystacks.append(projectId.lowercased()) }
        return haystacks.contains { $0.contains(needle) }
    }

    /// Stable newest-first ordering, shared by both thread lists.
    ///
    /// Rows whose `updatedAt` cannot be parsed sink below every dated row and
    /// keep the order they arrived in; two rows with the same instant keep
    /// their relative order too, so the list never reshuffles between reloads
    /// of the same data.
    public static func newestFirst(_ sessions: [AcpSessionInfo]) -> [AcpSessionInfo] {
        sessions.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.updated, rhs.element.updated) {
                case let (l?, r?):
                    return l == r ? lhs.offset < rhs.offset : l > r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.offset < rhs.offset
                }
            }
            .map { $0.element }
    }
}