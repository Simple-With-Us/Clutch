import SwiftUI
import Foundation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The thread rail, shared by the Mac chat surface and the iPhone/iPad
/// dashboard so both platforms show one thread list.
///
/// On macOS this is a pinned 248pt rail beside the transcript.  On iOS it is
/// the sidebar column of a `NavigationSplitView`, where the system sizes the
/// column and a tap pushes the thread instead of swapping the pane — so
/// `fixedWidth` is nil there.
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
    var onSelect: (AcpSessionInfo) -> Void
    var onNew: () -> Void
    var onRefresh: () -> Void
    /// Locally pinned thread ids (see `ThreadPinStore`); rendered as their
    /// own group above the date buckets when non-empty.
    var pinnedIds: Set<String> = []
    var onTogglePin: ((AcpSessionInfo) -> Void)?
    /// macOS pins the rail width; a split view lets the system choose, so iOS
    /// passes nil and lets the column breathe.
    var fixedWidth: CGFloat? = 248

    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
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

            if ordered.isEmpty && loading {
                ProgressView("Loading Threads…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if ordered.isEmpty {
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
    }

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

            Text("Threads")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if !ordered.isEmpty {
                Text("\(ordered.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.clutchSecondaryBackground, in: Capsule())
            }

            Spacer(minLength: 0)

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
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No Threads Yet")
                .font(.system(size: 12, weight: .semibold))
            Text("Start One With The Button Above.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        if let selected = ordered.first(where: { $0.sessionId == selectedId }), let cwd = selected.cwd, !cwd.isEmpty {
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
    }

    private func row(_ session: AcpSessionInfo) -> some View {
        ThreadSidebarRow(
            session: session,
            isSelected: session.sessionId == selectedId,
            isLoading: loadingId == session.sessionId,
            isDisabled: loadingId != nil && loadingId != session.sessionId,
            onSelect: onSelect,
            isPinned: pinnedIds.contains(session.sessionId),
            onTogglePin: onTogglePin
        )
    }

    /// Newest first.  `updatedAt` is a free-form string from the engine, so a
    /// value we cannot read sinks below the dated rows and keeps its listed
    /// order — a malformed date can never scramble or trap the list.
    private var ordered: [AcpSessionInfo] {
        AcpSessionInfo.newestFirst(sessions)
    }

    private var visibleGroups: [AcpSessionInfo.Group] {
        AcpSessionInfo.grouped(AcpSessionInfo.filtered(ordered, query: query), pinned: pinnedIds)
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
    var onSelect: (AcpSessionInfo) -> Void
    var isPinned: Bool = false
    var onTogglePin: ((AcpSessionInfo) -> Void)?

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
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                    }
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
        .help(session.cwd ?? session.sessionId)
        .contextMenu {
            Button("Open Thread") { onSelect(session) }
            if let onTogglePin {
                Button(isPinned ? "Unpin Thread" : "Pin Thread") { onTogglePin(session) }
            }
            Divider()
            Button("Copy Session ID") { copy(session.sessionId) }
            if let cwd = session.cwd, !cwd.isEmpty {
                Button("Copy Working Directory") { copy(cwd) }
            }
        }
        #endif
    }

    #if os(macOS)
    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    #endif
}

extension AcpSessionInfo {
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
