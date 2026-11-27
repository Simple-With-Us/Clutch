import SwiftUI

/// A separate store per window keeps a host picked in this window from changing the
/// host another window shows.  The store does not write the active host to the
/// preferences (`persistsActiveHost: false`), so picking a host here never
/// overwrites the main window's choice either.  The window starts on the host its
/// request names, and the host switcher in the window changes what it shows.
struct MacThreadWindow: View {
    @Binding var request: MacThreadWindowRequest?
    @State private var store = HostStore(persistsActiveHost: false)
    /// The request (by its window id) the store's active host was last set for.
    @State private var seededFor: UUID?

    /// The host the request names, or nil when it is no longer paired.
    private var requestedHost: ClutchHost? {
        guard let request else { return nil }
        return store.hosts.first(where: { $0.id == request.hostID })
    }

    /// The host this window shows.  A host that is not paired shows the unavailable
    /// view, whatever the switcher picked before.  Once the window has started for
    /// its request, the switcher's pick (the store's active host) is what shows.
    private var windowHost: ClutchHost? {
        guard let request, let requested = requestedHost else { return nil }
        return seededFor == request.windowID ? (store.activeHost ?? requested) : requested
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
        .onAppear(perform: seed)
        .onChange(of: request?.windowID) { _, _ in seed() }
    }

    /// Starts the window on its request's host.  Runs again when the request changes,
    /// so a window reused for another thread starts on that thread's host.  A request
    /// whose host is not paired is left unseeded and shows the unavailable view.
    private func seed() {
        guard let request, let host = requestedHost, seededFor != request.windowID else { return }
        store.activate(host)
        seededFor = request.windowID
    }
}
