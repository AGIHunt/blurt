import AVFoundation
import SwiftUI

struct PairSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var failed = false
    private let hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if hasCamera {
                    Scanner { code in if open(code) { dismiss() } }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                Text("On your Mac, open Blurt’s Settings and choose iPhone.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !hasCamera {
                    TextField("Pairing link", text: $link)
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Connect") { if open(link) { dismiss() } }.disabled(link.isEmpty)
                }
                if failed { Text("This code isn’t from Blurt.").font(.footnote).foregroundStyle(.orange) }
                Spacer()
            }
            .padding(20)
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func open(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), Link.shared.open(u) else { failed = true; return false }
        Haptics.grab()
        return true
    }
}

private struct Scanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode) }
    func updateUIViewController(_ c: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?

    init(_ onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            guard ok else { return }
            DispatchQueue.main.async { self?.begin() }
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
        guard let s = (m.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        onCode(s)
    }
}
