import SwiftUI
import AVFoundation
import VisionKit

/// Camera QR scanner for the pairing code that `clutch-pair-ios` shows on the Mac.
public struct PairingScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let onPaired: (PairingPayload) -> Void

    @State private var cameraAuthorized: Bool = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var permissionResolved: Bool = AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined
    @State private var scanErrorMessage: String?

    public init(onPaired: @escaping (PairingPayload) -> Void) {
        self.onPaired = onPaired
    }

    public var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    ContentUnavailableView {
                        Label("Scanner Unavailable", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text(Copy.gap("This device cannot scan codes.", "Paste the pairing link instead."))
                    }
                } else if !permissionResolved {
                    ProgressView("Requesting camera access…")
                } else if !cameraAuthorized {
                    ContentUnavailableView {
                        Label("Camera Access Required", systemImage: "camera.fill")
                    } description: {
                        Text("Allow camera access to scan the pairing code shown on your Mac.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if !DataScannerViewController.isAvailable {
                    ContentUnavailableView {
                        Label("Scanner Unavailable", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text(Copy.gap("The camera is not available right now.", "Paste the pairing link instead."))
                    }
                } else {
                    ZStack(alignment: .bottom) {
                        VisionKitQRScanner { rawPayload in
                            handleScannedPayload(rawPayload)
                        }
                        .ignoresSafeArea(edges: .bottom)

                        Text(scanErrorMessage ?? "Point the camera at the pairing code on your Mac.")
                            .font(.system(size: 14, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundColor(scanErrorMessage == nil ? .primary : .red)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                            .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Scan Pairing Code")
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
        case .notDetermined:
            cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            cameraAuthorized = false
        }
        permissionResolved = true
    }

    private func handleScannedPayload(_ payload: String) -> Bool {
        switch PairingLink.parse(payload) {
        case .success(let pairing):
            onPaired(pairing)
            dismiss()
            return true
        case .failure(let error):
            scanErrorMessage = error.message
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

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCodeScanned: (String) -> Bool
        private var didSucceed = false

        init(onCodeScanned: @escaping (String) -> Bool) {
            self.onCodeScanned = onCodeScanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didSucceed, let first = addedItems.first else { return }
            if case let .barcode(code) = first, let payload = code.payloadStringValue, onCodeScanned(payload) {
                didSucceed = true
                dataScanner.stopScanning()
            }
        }
    }
}
