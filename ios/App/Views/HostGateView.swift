import SwiftUI

/// The native card for the two states the web canvas used to draw: the host
/// is not paired with this device, or it cannot be reached.
///
/// The canvas carried these states because it was the only surface that
/// talked to the web origin.  The native apps ask the sidecar instead, and
/// draw the same two cards with the same pairing controls, so nothing the
/// canvas said to the owner is lost with it.
struct HostGateView: View {
    let host: ClutchHost
    let store: HostStore
    let state: HostGateState
    let onRetry: () -> Void
    let onSwitchHost: () -> Void
    let onPaired: (PairingPayload) -> Void

    var body: some View {
        ZStack {
            Color.clutchBackground
                .ignoresSafeArea()
            VStack(spacing: 0) {
                // The picker stays on the card, the way the canvas kept it in
                // its toolbar: the owner must be able to pick another server
                // from here, and the dot must say what the gate knows rather
                // than what the probe thinks.
                HStack {
                    HostSwitcher(host: host, store: store, compact: true, status: state.pickerStatus)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.clutchSecondaryBackground.opacity(0.6))

                StateCard(
                    symbol: symbol,
                    title: title,
                    message: message
                ) {
                    actions
                }
            }
        }
    }

    private var symbol: String {
        switch state {
        case .ready: return "checkmark.circle"
        case .needsPairing: return "key.horizontal"
        case .unreachable: return "wifi.exclamationmark"
        }
    }

    private var title: String {
        switch state {
        case .ready: return host.name
        case .needsPairing: return "Pair This Device"
        case .unreachable: return "Cannot Reach \(host.name)"
        }
    }

    private var message: String {
        switch state {
        case .ready:
            return ""
        case .needsPairing:
            return Copy.gap(
                "\(host.name) needs a fresh pairing code.",
                "On the Mac, run \(Copy.pairCommand) and scan the code, or paste the link it copies."
            )
        case .unreachable(let reason):
            return Copy.gap(
                "Make sure Tailscale is connected on this device and clutch is running on the Mac.",
                reason
            )
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            switch state {
            case .ready:
                EmptyView()
            case .needsPairing:
                PairingActions { payload in
                    onPaired(payload)
                }
                Button {
                    onSwitchHost()
                } label: {
                    Text("Switch Host").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            case .unreachable:
                Button {
                    onRetry()
                } label: {
                    Text("Try Again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    onSwitchHost()
                } label: {
                    Text("Switch Host").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }
}

/// Full-screen native card covering the surface it is put over, for the
/// states that stop a surface from working at all.
struct StateCard<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.tint)
                    .padding(.top, 48)
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                actions()
                    .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color.clutchBackground)
    }
}
