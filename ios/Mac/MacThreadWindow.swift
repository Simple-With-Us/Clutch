import SwiftUI

/// A separate store per window keeps a host picked in this window from changing the
/// host another window shows.  The store does not write the active host to the
/// preferences (`persistsActiveHost: false`), so picking a host here never
/// overwrites the main window's choice either.  The window starts on the host its
/// request names, and the host switcher in the window changes what it shows.
struct MacThreadWindow: View {
    @Binding var request: MacThreadWindowRequest?
    @State private var store = HostStore(persistsActiveHost: false)
    @State private var seeded = false

    /// The host this window shows: the one its request names until the window has
    /// started, then whichever host the window's switcher last picked.
    private var windowHost: ClutchHost? {
        guard let request else { return nil }
        if seeded { return store.activeHost }
        return store.hosts.first(where: { $0.id == request.hostID })
    }

    var body: some View {
        Group {
            if let request, let host = windowHost {
                ChatView(
                    activeHost: host,
                    store: store,
                    initialSurface: .workspace,
                    // A thread belongs to the host it was opened on.
                    initialThreadRequest: host.id == request.hostID ? request : nil
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
        .onAppear {
            guard !seeded else { return }
            if let request, let host = store.hosts.first(where: { $0.id == request.hostID }) {
                store.activate(host)
            }
            seeded = true
        }
    }
}
