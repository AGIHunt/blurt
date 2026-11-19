// The host's picture in a viewer's window (docs/design/remote-desktop-viewer.md): pieces to frames with the same repairs as a phone (NACK,
// LTR refresh, parity: RemoteVideoReceiver), frames through the shared decoder (RemoteScreenDecoder), a report on what arrived every second.
// Where the pictures go is the app's (onFrame).
import CoreVideo
import Foundation
import QuartzCore

public final class RemoteViewerScreen {
    private let q = DispatchQueue(label: "blurt.viewer.screen", qos: .userInteractive)
    private let link: RemoteViewerLink
    private var receiver = RemoteVideoReceiver(nack: false, ltr: false)
    private let decoder = RemoteScreenDecoder()
    private var repairTimer: DispatchSourceTimer?
    private var reportTimer: DispatchSourceTimer?
    private var on = false
    private var reportFrames = 0, reportBytes = 0, reportDropped = 0, pictureBytes = 0, quietReports = 0
    private var reportAt = CACurrentMediaTime()
    /// what this viewer offers (RemoteVideoFeature): all of them, as an Apple phone
    public static let features: [String] = RemoteVideoFeature.all

    /// A decoded picture and the part of the screen it shows, from VideoToolbox's thread.
    public var onFrame: ((CVImageBuffer, RemoteCrop) -> Void)?
    /// frames decoded since the picture started, and their bytes (for the measured runs and the tests)
    public private(set) var decoded = 0
    public private(set) var bytes = 0

    public init(link: RemoteViewerLink) { self.link = link }

    /// Ask for the picture: from now on the host sends it, and this decodes it.
    public func start(_ r: RemoteScreenRequest) {
        q.async {
            self.reset()
            self.on = true
            self.pictureBytes = 0
            self.link.send(.screen(r))
            self.watch()
        }
    }

    /// The same picture, another size or display: the host restarts its stream without a gap here.
    public func change(_ r: RemoteScreenRequest) { link.send(.screen(r)) }

    public func stop(tell: Bool = true) {
        q.async {
            guard self.on else { return }
            self.on = false
            self.repairTimer?.cancel()
            self.repairTimer = nil
            self.reportTimer?.cancel()
            self.reportTimer = nil
            if tell { self.link.send(.screen(nil)) }
            self.reset()
        }
    }

    /// `screenView`: the codec, and the repairs the host uses. Another codec than the frames so far: from a keyframe.
    public func view(codec: String?, features: [String]?) {
        q.async {
            if self.decoder.told(codec) { self.reset() }
            let f = Set(features ?? [])
            self.receiver.nack = f.contains(RemoteVideoFeature.nack)
            self.receiver.ltr = f.contains(RemoteVideoFeature.ltr)
        }
    }

    /// A video piece (frame kind 3), from any queue.
    public func packet(_ d: Data) {
        q.async {
            guard self.on, let p = RemoteVideoPacket(d) else { return }
            self.reportBytes += d.count
            self.pictureBytes += p.payload.count
            self.bytes += d.count
            self.handle(self.receiver.add(p, now: CACurrentMediaTime()))
        }
    }

    private func reset() {
        receiver = RemoteVideoReceiver(nack: receiver.nack, ltr: receiver.ltr, now: CACurrentMediaTime())
        receiver.rtt = link.rtt ?? 0.01
        reportDropped = 0
        decoder.reset()
    }

    private func handle(_ out: [RemoteVideoReceiver.Output]) {
        for o in out {
            switch o {
            case let .frame(f): decode(f)
            case let .feedback(f): link.sendDatagram(.videoFeedback, f.encoded())
            case .keyframe: link.send(.requestKeyframe)
            }
        }
    }

    private func decode(_ f: RemoteVideoAssembler.Frame) {
        decoder.decode(f) { [weak self] st, image, crop in
            guard let self else { return }
            guard st == noErr, let image else {
                if st != noErr {
                    self.q.async {
                        self.decoder.reset()
                        self.receiver.decoderFailed(now: CACurrentMediaTime())
                    }
                }
                return
            }
            let now = CACurrentMediaTime()
            self.q.async {
                self.reportFrames += 1
                self.decoded += 1
                self.handle(self.receiver.decoded(f, now: now))
            }
            self.onFrame?(image, crop)
        }
    }

    /// Every 4 ms: pieces asked for again, frames given up, a keyframe when nothing arrives. Every second: what arrived, for the host's rate.
    private func watch() {
        repairTimer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: q)
        t.schedule(deadline: .now() + 0.004, repeating: 0.004, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, self.on else { return }
            self.handle(self.receiver.tick(now: CACurrentMediaTime()))
        }
        t.resume()
        repairTimer = t
        reportTimer?.cancel()
        reportAt = CACurrentMediaTime()
        let r = DispatchSource.makeTimerSource(queue: q)
        r.schedule(deadline: .now() + 1, repeating: 1)
        r.setEventHandler { [weak self] in self?.report() }
        r.resume()
        reportTimer = r
    }

    private func report() {
        let lost = max(0, receiver.dropped - reportDropped), frames = reportFrames, sent = reportBytes, received = pictureBytes
        reportDropped = receiver.dropped
        reportFrames = 0
        reportBytes = 0
        reportAt = CACurrentMediaTime()
        let rtt = link.rtt
        if let rtt { receiver.rtt = rtt }
        quietReports = sent == 0 ? quietReports + 1 : 0
        guard quietReports == 0 || quietReports % 5 == 0 else { return }
        link.send(.screenReport(RemoteScreenReport(frames: frames, lost: lost, rtt: rtt, received: received)))
    }
}
