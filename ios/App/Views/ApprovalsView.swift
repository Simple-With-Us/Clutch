import SwiftUI

/// The approvals waiting for the owner on this host.
///
/// It is the list the Live Activity and the Control Center action open, and
/// it shows what the home list shows:  the thread's name and that the
/// engine wants an approval.  The tool and its evidence are behind the
/// thread, where the owner can read them before answering.
struct ApprovalsView: View {
    let host: ClutchHost
    /// Opens the thread an approval belongs to.
    let onOpenThread: (String) -> Void

    /// What this host is waiting on and what it is running.
    ///
    /// The split takes a thread that is waiting on the owner out of the
    /// running list, because the turn has not ended:  the thread is
    /// blocked, not working, and it is one row and not two.
    private var work: (waiting: [TurnActivityApproval], running: [TurnActivityRun]) {
        ClutchActivityWork.split(
            approvals: TurnActivity.shared.approvals.filter { $0.hostId == host.id },
            runs: TurnActivity.shared.runs.filter { $0.hostId == host.id }
        )
    }

    var body: some View {
        if work.waiting.isEmpty && work.running.isEmpty {
            ContentUnavailableView(
                "Nothing Waiting",
                systemImage: "checkmark.circle",
                description: Text("No approvals are waiting on this host.")
            )
        } else {
            List {
                if !work.waiting.isEmpty {
                    Section("Needs You") {
                        ForEach(work.waiting) { approval in
                            Button {
                                onOpenThread(approval.sessionId)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(ClutchFont.caption)
                                        .foregroundStyle(ClutchColor.warning)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(approval.title)
                                            .font(ClutchFont.captionStrong)
                                            .lineLimit(1)
                                        Text("Wants approval")
                                            .font(ClutchFont.micro)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Approval wanted by \(approval.title)")
                        }
                    }
                }
                if !work.running.isEmpty {
                    Section("Running") {
                        ForEach(work.running) { run in
                            Button {
                                onOpenThread(run.sessionId)
                            } label: {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 14, height: 14)
                                    Text(run.title)
                                        .font(ClutchFont.captionStrong)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Running: \(run.title)")
                        }
                    }
                }
            }
        }
    }
}
