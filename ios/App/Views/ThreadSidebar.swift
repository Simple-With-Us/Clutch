import SwiftUI
import Foundation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// What a right-click on a thread row can do.
///
/// Modelled as one enum rather than a dozen callbacks so the sidebar stays a
/// dumb surface:  it reports intent, and `ChatViewMac` decides what actually
/// happens.  Every case here is real —  the ones the sidecar cannot yet do are
/// absent rather than shown and silently ignored.
public enum ThreadSidebarAction {
    /// Move a thread into a Project, or out of all of them when `nil`.
    case assignProject(AcpSessionInfo, String?)
    /// Create a Project with this name and assign the thread to it.
    case createProject(String, AcpSessionInfo)
    /// Archive or restore a thread.  Archiving hides it and is reversible.
    case setArchived(AcpSessionInfo, Bool)
    /// Open the thread's working directory in Finder.
    case revealInFinder(AcpSessionInfo)
    /// Rename the Clutch-side title without changing the engine session.
    case renameThread(AcpSessionInfo)
    /// Open a read-only preview in an independent Mac window.
    case openInNewWindow(AcpSessionInfo)
}

/// The thread rail, shared by the Mac chat surface and the iPhone/iPad
/// dashboard so both platforms show one thread list.
///
/// On macOS this is a drag-resizable rail beside the transcript, 248pt until
/// the user drags it.  On iOS it is the sidebar column of a
/// `NavigationSplitView`, where the system sizes the column and a tap pushes
/// the thread instead of swapping the pane — so `fixedWidth` is nil there and
/// every macOS affordance below is compiled out.
///
/// The error banner is rendered above the list rather than in a branch the
/// loaded-list state can shadow.  That is deliberate: a failed resume used to
/// be assigned to a branch that was unreachable once the list had loaded, so
/// tapping a thread looked like it did nothing at all.
struct ThreadSidebar: View {
    /// Thread list as handed over; this view sorts and groups it itself
    /// (see `visibleGroups`), so the caller may pass the sidecar's raw order.
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
    /// Open a fresh workspace in another Mac window.  Unused on iOS.
    var onNewWindow: (() -> Void)? = nil
    var onRefresh: () -> Void
    /// Retry the failed thread action; defaults to refreshing the list.
    var onRetry: (() -> Void)? = nil
    /// Context-menu actions the host handles.  nil leaves those items out.
    var onAction: ((ThreadSidebarAction, AcpSessionInfo) -> Void)? = nil
    /// Whether archived threads are listed (marked, restorable) or hidden.
    var showArchived: Bool = false
    /// Flip `showArchived` and reload.  Without this, archiving a thread made
    /// it unreachable: every list call excluded archived rows, so the restore
    /// action could never be reached.
    var onToggleArchived: (() -> Void)? = nil
    /// Locally pinned thread ids (see `ThreadPinStore`); rendered as their
    /// own group above the date buckets when non-empty.
    var pinnedIds: Set<String> = []
    var onTogglePin: ((AcpSessionInfo) -> Void)?
    /// Current folder filter.  nil means all folders.
    var folderScope: String? = nil
    /// Folder roots discovered in the loaded session pages.
    var folders: [String] = []
    var onChooseFolderScope: ((String?) -> Void)? = nil
    var canLoadMore: Bool = false
    var isLoadingMore: Bool = false
    var onLoadMore: (() -> Void)? = nil
    /// macOS pins the rail width; a split view lets the system choose, so iOS
    /// passes nil and lets the column breathe.
    var fixedWidth: CGFloat? = 248
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

    static func promptForThreadTitle(currentTitle: String?) -> String?? {
        let alert = NSAlert()
        alert.messageText = "Rename Thread"
        alert.informativeText = "Leave the title blank to use the default thread name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Thread Name"
        field.stringValue = currentTitle ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return .some(trimmed.isEmpty ? nil : trimmed)
    }
    #endif

    @State private var query: String = ""
    @State private var hoveredId: String?

    var body: some View {
        let ordered = AcpSessionInfo.newestFirst(sessions)
        let filtered = ThreadSidebarGrouping.filtered(ordered, query: query, projects: projects)
        let visibleGroups = ThreadSidebarGrouping.groups(
            ordered: filtered,
            projects: projects,
            pinned: pinnedIds
        )

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                searchField
                #if os(macOS)
                if let onChooseFolderScope {
                    folderScopePicker(onChooseFolderScope)
                }
                #endif
                Divider()

                if let errorText, !errorText.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorText)
                            .font(.system(size: 11))
                            .lineLimit(4)
                            .truncationMode(.tail)
                            .help(errorText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Retry", action: onRetry ?? onRefresh)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12))
                    Divider()
                }

                if sessions.isEmpty && loading {
                    ProgressView("Loading Threads…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sessions.isEmpty {
                    emptyState
                } else if visibleGroups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text("No Threads Match")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Nothing here matches \u{201C}\(query)\u{201D}.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("Clear Filter") { query = "" }
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(visibleGroups) { group in
                                Text(group.title.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 10)
                                    .padding(.bottom, 2)
                                ForEach(group.sessions) { session in
                                    row(session)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                }

                footer
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
            .help("New Thread (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
            #endif

            #if os(macOS)
            if let onNewWindow {
                Button(action: onNewWindow) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Thread In New Window")
                .help("New Thread In New Window")
            }
            #endif

            Text("Threads")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if !sessions.isEmpty {
                Text("\(sessions.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.clutchSecondaryBackground, in: Capsule())
            }

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
                .help("Refresh Threads (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
                #endif
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    #if os(macOS)
    private func folderScopePicker(_ choose: @escaping (String?) -> Void) -> some View {
        Menu {
            Button("All Folders") { choose(nil) }
            if !folders.isEmpty { Divider() }
            ForEach(folders.sorted(), id: \.self) { folder in
                Button {
                    choose(folder)
                } label: {
                    if folder == folderScope {
                        Label(folder, systemImage: "checkmark")
                    } else {
                        Text(folder)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(folderScope.map { "Folder + Subfolders: \(($0 as NSString).lastPathComponent)" } ?? "All Folders")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.clutchSecondaryBackground, in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .help(folderScope.map { "Showing this folder and its subfolders: \($0)" } ?? "Showing threads from all folders")
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
    }
    #endif

    /// One search field for the rail.  `AcpSessionInfo.filtered` matches the
    /// thread name, folder, session id, model, provider and project, so a user
    /// who remembers any one of them can find the thread.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter Threads", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.clutchSecondaryBackground, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        #if os(macOS)
        .help("Search threads by name, folder, ID or model.")
        #endif
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No Threads Yet")
                .font(.system(size: 12, weight: .semibold))
            Text("Start one with the button above.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        if (sessions.first(where: { $0.sessionId == selectedId })?.cwd?.isEmpty == false) || canLoadMore {
            VStack(spacing: 0) {
                if let selected = sessions.first(where: { $0.sessionId == selectedId }), let cwd = selected.cwd, !cwd.isEmpty {
                    Divider()
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(cwd)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    #if os(macOS)
                    .help(cwd)
                    #endif
                }
                if canLoadMore {
                    Button {
                        onLoadMore?()
                    } label: {
                        HStack(spacing: 6) {
                            if isLoadingMore { ProgressView().controlSize(.small) }
                            Text(isLoadingMore ? "Loading More Threads…" : "Load More Threads")
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingMore)
                }
            }
        }
    }

    private func row(_ session: AcpSessionInfo) -> some View {
        ThreadSidebarRow(
            session: session,
            isSelected: session.sessionId == selectedId,
            isHovered: hoveredId == session.sessionId,
            isLoading: loadingId == session.sessionId,
            isDisabled: false,
            projects: projects,
            showsTooltip: false,
            onSelect: onSelect,
            isPinned: pinnedIds.contains(session.sessionId),
            onTogglePin: onTogglePin,
            onAction: onAction
        )
        #if os(macOS)
        .onHover { inside in
            hoveredId = inside ? session.sessionId : (hoveredId == session.sessionId ? nil : hoveredId)
        }
        #endif
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
    var isHovered: Bool = false
    var isLoading: Bool
    var isDisabled: Bool
    var projects: [SessionsClient.Project] = []
    /// Show the full folder as a macOS tooltip.  Off where a hover card
    /// already shows it.
    var showsTooltip: Bool = true
    var onSelect: (AcpSessionInfo) -> Void
    var isPinned: Bool = false
    var onTogglePin: ((AcpSessionInfo) -> Void)?
    /// Handles the Project, Archive and Finder items of the context menu.
    /// nil where no surface handles them (the Mac Code tab's thread list), so
    /// those items are left out there instead of shown and silently ignored.
    var onAction: ((ThreadSidebarAction, AcpSessionInfo) -> Void)? = nil

    @State private var showingDetails = false

    var body: some View {
        Button {
            onSelect(session)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        Text(session.displayTitle)
                            .font(.system(size: 12, weight: isSelected || isLoading ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    if isLoading {
                        Text("Opening…")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    } else {
                        HStack(spacing: 4) {
                            if let cwd = session.cwd, !cwd.isEmpty {
                                Image(systemName: "folder")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                Text((cwd as NSString).lastPathComponent)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if session.cwd?.isEmpty == false, session.updated != nil {
                                Text("·")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            if let when = session.updated {
                                Text(when, style: .relative)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        // The one usage fact cheap enough to show inline on every
                        // row.  Absent rather than estimated when the engine has not
                        // reported a window.
                        if let usage = session.usage,
                           let occupancy = ThreadMetricPresentation.contextOccupancyLabel(usage) {
                            Text(occupancy)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected || isLoading
                    ? Color.accentColor.opacity(0.18)
                    : isHovered ? Color.primary.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        // VoiceOver needs the thread named, not just its working directory.
        .accessibilityLabel(isLoading ? "Opening Thread, \(session.displayTitle)" : "Thread, \(session.displayTitle)")
        .accessibilityValue(isLoading ? "Opening" : isSelected ? "Selected" : "")
        #if os(macOS)
        // The row shows only the folder's last component, so the tooltip
        // carries the full path.  The Mac rail shows that path in Thread Details.
        .help(showsTooltip ? (session.cwd ?? session.sessionId) : "")
        .accessibilityAction(named: Text("Show Thread Details")) { showingDetails = true }
        .contextMenu { menu }
        .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
            ThreadDetailsCard(session: session, projects: projects)
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var menu: some View {
        Button("Preview Thread") { onSelect(session) }
        Button("Show Thread Details") { showingDetails = true }

        if let onTogglePin {
            Button(isPinned ? "Unpin Thread" : "Pin Thread") { onTogglePin(session) }
        }

        Divider()

        Button("Copy Session ID") { copy(session.sessionId) }

        if let cwd = session.cwd, !cwd.isEmpty {
            Button("Copy Working Directory") { copy(cwd) }
        }

        if let onAction {
            Button("Open In New Window") { onAction(.openInNewWindow(session), session) }
            Button("Rename Thread…") { onAction(.renameThread(session), session) }
            Divider()
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
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
            detail("Model", session.model ?? session.usage?.model ?? "Not reported")
            detail("Provider", session.provider ?? session.usage?.provider ?? "Not reported")

            if let usage = session.usage {
                Divider()
                if let basis = usage.basis {
                    detail("Usage Basis", basis == "session-totals" ? "Session Totals" : basis == "latest-response" ? "Latest Response" : basis)
                }
                detail(
                    "Context Used",
                    ThreadMetricPresentation.contextOccupancyLabel(usage) ?? "Not reported",
                    monospaced: true
                )
                let totalsArePartial = usage.totalsComplete == false && usage.basis != "latest-response"
                tokenDetail("Input Tokens", value: usage.inputTokens, reported: usage.inputTokensReported, partial: totalsArePartial)
                tokenDetail("Output Tokens", value: usage.outputTokens, reported: usage.outputTokensReported, partial: totalsArePartial)
                responseRateDetail(usage)
                detail(
                    totalsArePartial ? "Cached Input Tokens (Partial)" : "Cached Input Tokens",
                    (usage.cachedTokens ?? usage.cacheReadTokens).map(AcpSessionUsage.compact) ?? "Not reported",
                    monospaced: true
                )
            } else {
                Divider()
                Text("No usage reported for this thread yet.")
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

    private func tokenDetail(_ label: String, value: Int, reported: Bool?, partial: Bool) -> some View {
        let hasValue = reported == true || (reported == nil && value > 0)
        let displayLabel = partial ? "\(label) (Partial)" : label
        return detail(displayLabel, hasValue ? AcpSessionUsage.compact(value) : "Not reported", monospaced: true)
    }

    private func responseRateDetail(_ usage: AcpSessionUsage) -> some View {
        let value = ThreadMetricPresentation.responseRateLabel(usage)
        let duration = usage.completionDurationMs.map { milliseconds in
            milliseconds >= 1000 ? String(format: "%.2f seconds", milliseconds / 1000) : String(format: "%.0f milliseconds", milliseconds)
        } ?? "Not reported"
        return detail("Response Rate", value, monospaced: true)
            .help(Copy.gap("Rate for the most recent response.", "Completion duration, including latency: \(duration)."))
    }
}

enum ThreadMetricPresentation {
    static func contextOccupancyLabel(_ usage: AcpSessionUsage) -> String? {
        // `totalTokens == 0` is a placeholder when context is unreported; an explicit context count may be a real zero.
        guard usage.contextUsedTokens != nil || usage.totalTokens > 0 else { return nil }
        return usage.occupancyLabel
    }

    static func responseRateLabel(_ usage: AcpSessionUsage) -> String {
        guard let rate = usage.responseTokensPerSecond, rate.isFinite, rate >= 0 else { return "Not reported" }
        return String(format: "%.1f tok/s", rate)
    }
}

extension AcpSessionInfo {
    /// Stable newest-first ordering, shared by both thread lists.
    ///
    /// Rows whose `updatedAt` cannot be parsed sink below every dated row and
    /// keep the order they arrived in; two rows with the same instant keep
    /// their relative order too, so the list never reshuffles between reloads
    /// of the same data.
    public static func newestFirst(_ sessions: [AcpSessionInfo]) -> [AcpSessionInfo] {
        let dated = sessions.enumerated().map { entry in
            (index: entry.offset, session: entry.element, date: entry.element.updated)
        }
        return dated
            .sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case let (l?, r?):
                    return l == r ? lhs.index < rhs.index : l > r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.index < rhs.index
                }
            }
            .map(\.session)
    }
}

struct ThreadSidebarGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var sessions: [AcpSessionInfo]
}

enum ThreadSidebarGrouping {
    static func filtered(
        _ sessions: [AcpSessionInfo],
        query: String,
        projects: [SessionsClient.Project]
    ) -> [AcpSessionInfo] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sessions }

        let matchingSessions = Set(AcpSessionInfo.filtered(sessions, query: needle).map(\.sessionId))
        let matchingProjectIds = Set(
            projects
                .filter { $0.name.lowercased().contains(needle) }
                .map(\.id)
        )
        return sessions.filter { session in
            matchingSessions.contains(session.sessionId)
                || session.projectId.map(matchingProjectIds.contains) == true
        }
    }

    static func groups(
        ordered sessions: [AcpSessionInfo],
        projects: [SessionsClient.Project],
        pinned: Set<String>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ThreadSidebarGroup] {
        var seen = Set<String>()
        let uniqueSessions = sessions.filter { seen.insert($0.sessionId).inserted }
        var remaining = uniqueSessions.filter { !pinned.contains($0.sessionId) }
        var groups: [ThreadSidebarGroup] = []

        let pinnedRows = uniqueSessions.filter { pinned.contains($0.sessionId) }
        if !pinnedRows.isEmpty {
            groups.append(ThreadSidebarGroup(id: "pinned", title: "Pinned", sessions: pinnedRows))
        }

        let sortedProjects = projects.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for project in sortedProjects {
            let projectRows = remaining.filter { $0.projectId == project.id }
            guard !projectRows.isEmpty else { continue }
            let title = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            groups.append(ThreadSidebarGroup(
                id: "project:\(project.id)",
                title: title.isEmpty ? "Unnamed Project" : title,
                sessions: projectRows
            ))
            let projectSessionIds = Set(projectRows.map(\.sessionId))
            remaining.removeAll { projectSessionIds.contains($0.sessionId) }
        }

        let otherProjectRows = remaining.filter { $0.projectId != nil }
        if !otherProjectRows.isEmpty {
            groups.append(ThreadSidebarGroup(
                id: "other-projects",
                title: "Other Projects",
                sessions: otherProjectRows
            ))
            let otherSessionIds = Set(otherProjectRows.map(\.sessionId))
            remaining.removeAll { otherSessionIds.contains($0.sessionId) }
        }

        let unassigned = remaining.filter { $0.projectId == nil }
        for dateGroup in AcpSessionInfo.grouped(unassigned, now: now, calendar: calendar) {
            groups.append(ThreadSidebarGroup(
                id: "date:\(dateGroup.title)",
                title: dateGroup.title,
                sessions: dateGroup.sessions
            ))
        }
        return groups
    }
}
