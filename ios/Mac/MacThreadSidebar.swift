import SwiftUI
import Foundation

/// Left thread rail for the MiniMax Code engine, shaped like the MiniMax
/// Code desktop app: every local thread in one list, the open one
/// highlighted, and a new-thread button at the top.
///
/// This is now the only way to resume a thread — the "Resume Thread…" entry
/// points reveal this rail instead of opening a picker, so both routes run
/// through one code path (`ChatView.openSession`).
///
/// The error banner is rendered above the list rather than in a branch the
/// loaded-list state can shadow.  That is deliberate: a failed resume used to
/// be assigned to a branch that was unreachable once the list had loaded, so
/// tapping a thread looked like it did nothing at all.
struct MacThreadSidebar: View {
    /// Thread list as handed over; this view sorts it newest-first itself
    /// (see `ordered`), so the caller may pass the sidecar's raw order.
    var sessions: [AcpSessionInfo]
    var selectedId: String?
    var loading: Bool
    var loadingId: String?
    var errorText: String?
    var onSelect: (AcpSessionInfo) -> Void
    var onNew: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let errorText, !errorText.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
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
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(ordered) { session in
                            row(session)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 232)
        .background(Color.clutchBackground)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onNew) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("New Thread")

            Text("Threads")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

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
                .foregroundColor(.secondary)
                .help("Refresh Threads")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func row(_ session: AcpSessionInfo) -> some View {
        let isSelected = session.sessionId == selectedId
        let isLoading = loadingId == session.sessionId
        let when = Self.parse(session.updatedAt)
        return Button {
            onSelect(session)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title ?? "Untitled Thread")
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let cwd = session.cwd {
                            Text(cwd)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        if let when {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
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
        .disabled(loadingId != nil && !isLoading)
        .help(session.cwd ?? session.sessionId)
    }

    /// Newest first.  `updatedAt` is a free-form string from the engine, so a
    /// value we cannot read sinks below the dated rows and keeps its listed
    /// order — a malformed date can never scramble or trap the list.
    private var ordered: [AcpSessionInfo] {
        sessions.enumerated()
            .sorted { lhs, rhs in
                switch (Self.parse(lhs.element.updatedAt), Self.parse(rhs.element.updatedAt)) {
                case let (l?, r?): return l == r ? lhs.offset < rhs.offset : l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }
            .map { $0.element }
    }

    /// Sidecar sends ISO-8601, usually with milliseconds and a `Z` suffix.
    /// Returns nil for anything else so a malformed stamp is simply not shown
    /// rather than trapping on a bad date.
    private static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}