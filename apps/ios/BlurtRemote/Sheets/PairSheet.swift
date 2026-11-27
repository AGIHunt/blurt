import AVFoundation
import BlurtRemoteKit
import SwiftUI

struct PairSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// the link used last: after a pairing that didn't take, it's still here to try again or change
    @State private var link = Link.shared.lastLink
    @State private var failed: LocalizedStringKey?
    private let hasCamera = AVCaptureDevice.default(for: .video) != nil || Self.pretendCamera
    #if DEBUG
    /// `BLURT_REMOTE_PRETEND_CAMERA=1`: the Simulator, which has no camera, lays the sheet out as a phone's (black where the picture goes)
    private static let pretendCamera = ProcessInfo.processInfo.environment["BLURT_REMOTE_PRETEND_CAMERA"] != nil
    #else
    private static let pretendCamera = false
    #endif
    @State private var denied = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
    private var camera: Bool { hasCamera && !denied }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if camera {
                    Group { if Self.pretendCamera { Color.black } else { Scanner(onDenied: { denied = true }) { code in use(code, scanned: true) } } }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                Text(Words.whereTheCodeIs)
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if hasCamera, denied {
                    Text("Blurt can’t use the camera. Turn it on in Settings, or paste the pairing link below.")
                        .font(.subheadline).multilineTextAlignment(.center)
                    Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                }
                // the link the computer copies (Copy Link), for a code that's far away or won't read: Paste uses it at once, with no
                // question from iOS; the field takes it typed, or pasted inside a message
                HStack(spacing: 8) {
                    TextField("Pairing link", text: $link)
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).submitLabel(.go).onSubmit { use(link) }
                    PasteButton(payloadType: String.self) { got in
                        guard let s = got.first else { return }
                        DispatchQueue.main.async { link = s; use(s) }
                    }
                    .labelStyle(.titleOnly).buttonBorderShape(.capsule)
                }
                if !camera || !link.isEmpty {
                    Button("Connect") { use(link) }.disabled(link.isEmpty)
                }
                if let failed { Text(failed).font(.footnote).foregroundStyle(.orange) }
                Spacer()
            }
            .padding(20)
            .navigationTitle("Pair with a Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    /// A code the camera read, or text with the link in it (alone, or inside a message from a chat app).
    private func use(_ s: String, scanned: Bool = false) {
        guard let p = RemotePairing(text: s), Link.shared.open(p.url) else {
            failed = scanned ? "This code isn’t from Blurt." : "This isn’t a pairing link."
            return
        }
        if !scanned { Link.shared.lastLink = p.url.absoluteString }
        Haptics.grab()
        dismiss()
    }
}

private struct Scanner: UIViewControllerRepresentable {
    var onDenied: () -> Void = {}
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode, onDenied: onDenied) }
    func updateUIViewController(_ c: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var last: String?

    private let onDenied: () -> Void

    init(_ onCode: @escaping (String) -> Void, onDenied: @escaping () -> Void) {
        self.onCode = onCode
        self.onDenied = onDenied
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            DispatchQueue.main.async { if ok { self?.begin() } else { self?.onDenied() } }
        }
    }

    private func begin() {
        guard let d = AVCaptureDevice.default(for: .video), let i = try? AVCaptureDeviceInput(device: d), session.canAddInput(i) else { return }
        session.addInput(i)
        let o = AVCaptureMetadataOutput()
        guard session.canAddOutput(o) else { return }
        session.addOutput(o)
        o.setMetadataObjectsDelegate(self, queue: .main)
        o.metadataObjectTypes = [.qr]
        let p = AVCaptureVideoPreviewLayer(session: session)
        p.videoGravity = .resizeAspectFill
        p.frame = view.bounds
        view.layer.addSublayer(p)
        preview = p
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
    }

    func metadataOutput(_ o: AVCaptureMetadataOutput, didOutput m: [AVMetadataObject], from c: AVCaptureConnection) {
        // the same code is read over and over until the sheet has gone
        guard let s = (m.first as? AVMetadataMachineReadableCodeObject)?.stringValue, s != last else { return }
        last = s
        onCode(s)
    }
}
