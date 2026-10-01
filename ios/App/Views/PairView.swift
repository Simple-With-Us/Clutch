import SwiftUI
import UIKit

/// Rendered product copy helpers.  Sentences are joined with U+00A0 + space so
/// the two-space sentence gap survives SwiftUI text layout.
enum Copy {
    static let sentenceGap = "\u{00A0} "

    static func gap(_ sentences: String...) -> String {
        sentences.joined(separator: sentenceGap)
    }

    static let pairCommand = "clutch-pair-ios"
}

/// Scan / paste / type controls shared by first-run onboarding, Add Host, and
/// the "pairing expired" overlay.
struct PairingActions: View {
    let onPaired: (PairingPayload) -> Void

    @State private var isScanning = false
    @State private var manualEntry = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            Button {
                isScanning = true
            } label: {
                Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                pasteLink()
            } label: {
                Label("Paste Pairing Link", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            HStack(spacing: 8) {
                TextField("Link or address", text: $manualEntry)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connectManual)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                Button("Connect", action: connectManual)
                    .buttonStyle(.bordered)
                    .disabled(manualEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            #if targetEnvironment(simulator)
            Button {
                accept(.success(PairingPayload(name: "This Mac", origin: URL(string: "http://127.0.0.1:3180")!, launchToken: nil)))
            } label: {
                Label("Use This Mac (Simulator)", systemImage: "laptopcomputer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            #endif

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("pairing-error")
            }
        }
        .sheet(isPresented: $isScanning) {
            PairingScannerSheet { payload in
                accept(.success(payload))
            }
        }
    }

    private func pasteLink() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            errorMessage = Copy.gap("The clipboard is empty.", "Run \(Copy.pairCommand) on your Mac, then try again.")
            return
        }
        accept(PairingLink.parse(text))
    }

    private func connectManual() {
        accept(PairingLink.parse(manualEntry))
    }

    private func accept(_ result: Result<PairingPayload, PairingLinkError>) {
        switch result {
        case .success(let payload):
            errorMessage = nil
            manualEntry = ""
            onPaired(payload)
        case .failure(let error):
            errorMessage = error.message
        }
    }
}

/// First-run screen and the Add Host screen.
struct PairView: View {
    var showsIntro: Bool = true
    let onPaired: (PairingPayload) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if showsIntro {
                    AppIconBadge()
                        .padding(.top, 32)
                    VStack(spacing: 8) {
                        Text("Pair With Clutch")
                            .font(.largeTitle.weight(.bold))
                        Text(Copy.gap(
                            "Clutch runs on your Mac and reaches this device over Tailscale.",
                            "Open Terminal on the Mac and run \(Copy.pairCommand) to show a pairing code, then scan it here."
                        ))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    }
                }

                PairingActions(onPaired: onPaired)

                VStack(alignment: .leading, spacing: 6) {
                    Label("DeepSeek and MiniMax models", systemImage: "cpu")
                    Label("Sessions, streaming replies, and tools", systemImage: "bubble.left.and.text.bubble.right")
                    Label("Private to your tailnet", systemImage: "lock.shield")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The app icon shown in-app (a rounded crop is fine inside the app; the
/// shipped icon asset itself stays a full-bleed square).
struct AppIconBadge: View {
    var size: CGFloat = 96

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "h.square.fill")
                    .resizable()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}
