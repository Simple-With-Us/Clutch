import SwiftUI

/// A separate store per window prevents changing its selected host from
/// mutating another window's active view state.
struct MacThreadWindow: View {
    @Binding var request: MacThreadWindowRequest?
    @State private var store = HostStore()

    var body: some View {
        Group {
            if let request, let host = store.hosts.first(where: { $0.id == request.hostID }) {
                ChatView(
                    activeHost: host,
                    store: store,
                    initialSurface: .workspace,
                    initialThreadRequest: request
                )
            } else {
                ContentUnavailableView(
                    "Host Is Unavailable",
                    systemImage: "network.slash",
                    description: Text("Pair this host again or open a new thread from the workspace.")
                )
                .frame(minWidth: 720, minHeight: 480)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}
