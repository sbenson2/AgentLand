import AVFoundation
import SwiftUI

/// Why the scanner could not scan: camera access is off (Settings can turn it on), or the camera can't scan here.
enum PairingScanFailure: Equatable {
    case cameraDenied
    case unavailable(String)
}

struct PairingQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (PairingScanFailure) -> Void

    func makeUIViewController(context: Context) -> PairingCameraController {
        let controller = PairingCameraController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: PairingCameraController, context: Context) {
        controller.onCode = onCode
        controller.onFailure = onFailure
    }
}

final class PairingCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onFailure: ((PairingScanFailure) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.agentland.pairing.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var configured = false
    private var active = false
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        active = true
        delivered = false
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    if granted { self.startSession() }
                    else { self.onFailure?(.cameraDenied) }
                }
            }
        default:
            onFailure?(.cameraDenied)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        active = false
        stopSession()
        super.viewWillDisappear(animated)
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    self.reportFailure("The camera is unavailable on this device.")
                    return
                }
                self.session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard self.session.canAddOutput(output) else {
                    self.reportFailure("QR scanning is unavailable on this device.")
                    return
                }
                self.session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    self.reportFailure("QR scanning is unavailable on this camera.")
                    return
                }
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func reportFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            self.onFailure?(.unavailable(message))
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard active, !delivered,
              let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true
        stopSession()
        onCode?(code)
    }
}
