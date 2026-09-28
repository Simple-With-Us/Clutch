import SwiftUI
import AVFoundation
import VisionKit

public struct PairingScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let onPairScanned: (HostConnection) -> Void

    @State private var cameraAuthorized: Bool = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var permissionResolved: Bool = AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined
    @State private var scanErrorMessage: String?

    public init(onPairScanned: @escaping (HostConnection) -> Void) {
        self.onPairScanned = onPairScanned
    }

    public var body: some View {
        NavigationStack {
            Group {
                if !permissionResolved {
                    ProgressView("Requesting camera access…")
                } else if !cameraAuthorized {
                    ContentUnavailableView {
                        Label("Camera Access Required", systemImage: "camera.fill")
                    } description: {
                        Text("Allow camera access to scan the pairing QR code shown by your Mac or server.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if !DataScannerViewController.isSupported || !DataScannerViewController.isAvailable {
                    ContentUnavailableView {
                        Label("Scanner Unavailable", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text("Your device does not support VisionKit scanning.  Please enter your host details manually.")
                    }
                } else {
                    ZStack(alignment: .bottom) {
                        VisionKitQRScanner { rawPayload in
                            handleScannedPayload(rawPayload)
                        }
                        .ignoresSafeArea(edges: .bottom)

                        VStack(spacing: 8) {
                            Text(scanErrorMessage ?? "Point camera at the QR code on your Mac or server")
                                .font(.system(size: 14, weight: .medium))
                                .multilineTextAlignment(.center)
                                .foregroundColor(scanErrorMessage == nil ? .primary : .red)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Scan Pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await requestCameraPermission()
            }
        }
    }

    private func requestCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
            permissionResolved = true
        case .notDetermined:
            cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            permissionResolved = true
        default:
            cameraAuthorized = false
            permissionResolved = true
        }
    }

    private func handleScannedPayload(_ payload: String) -> Bool {
        guard let url = URL(string: payload) else {
            scanErrorMessage = "Scanned QR code is not a valid URL."
            return false
        }

        if let host = HostConnectionManager.shared.parsePairingURL(url) {
            HostConnectionManager.shared.addHost(host)
            HostConnectionManager.shared.setActiveHost(host)
            onPairScanned(host)
            dismiss()
            return true
        } else {
            scanErrorMessage = "Unrecognized QR code schema.  Expected harness://pair or minimax://pair."
            return false
        }
    }
}

struct VisionKitQRScanner: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Bool

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCodeScanned: (String) -> Bool
        private var didSucceed = false

        init(onCodeScanned: @escaping (String) -> Bool) {
            self.onCodeScanned = onCodeScanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didSucceed, let first = addedItems.first else { return }
            if case let .barcode(code) = first, let payload = code.payloadStringValue {
                if onCodeScanned(payload) {
                    didSucceed = true
                    dataScanner.stopScanning()
                }
            }
        }
    }
}
