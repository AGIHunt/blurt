// Offline Apple Vision probe. Never starts a camera or microphone.
// swiftc -O vision_probe.swift -o /tmp/blurt-vision-probe
import Foundation
import AVFoundation
import Vision

func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

func run() async throws {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--devices" {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        let devices: [[String: Any]] = discovery.devices.map { device in
            let formats: [[String: Any]] = device.formats.map { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return ["width": d.width, "height": d.height,
                        "max_fps": format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0]
            }
            return ["name": device.localizedName, "type": device.deviceType.rawValue,
                    "formats": formats]
        }
        try emit(["camera_started": false, "devices": devices])
        return
    }
    guard args.count >= 2 else {
        fputs("Usage: vision_probe VIDEO [MAX_FRAMES=250] [--anchors] | --devices\n", stderr)
        exit(2)
    }
    let limit = args.count > 2 ? Int(args[2]) ?? 0 : 250
    guard limit > 0 else { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "MAX_FRAMES must be positive"]) }
    let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw NSError(domain: "probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "No video track"])
    }
    // Input must have its rotation baked in; reject transforms to avoid silently measuring wrong geometry.
    guard try await track.load(.preferredTransform) == .identity else {
        throw NSError(domain: "probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Normalize video orientation with ffmpeg first"])
    }
    let reader = try AVAssetReader(asset: asset)
    let duration = try await asset.load(.duration).seconds
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error! }
    let request = VNDetectFaceLandmarksRequest()
    var times: [Double] = [], widths: [Double] = [], gaps: [Double] = []
    var anchorFrames: [Any] = []
    let includeAnchors = args.contains("--anchors")
    var found = 0, multiple = 0
    var lastTime: Double?
    var firstWidth = 0, firstHeight = 0
    let wallStart = CFAbsoluteTimeGetCurrent()
    while times.count < limit, let sample = output.copyNextSampleBuffer() {
        try autoreleasepool {
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // AVAssetReader can expose a preroll frame outside the movie's edit range.
            guard timestamp >= 0, timestamp < duration else { return }
            if let lastTime { gaps.append(timestamp - lastTime) }
            lastTime = timestamp
            firstWidth = CVPixelBufferGetWidth(pixel)
            firstHeight = CVPixelBufferGetHeight(pixel)
            let start = CFAbsoluteTimeGetCurrent()
            try VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .up).perform([request])
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let faces = request.results ?? []
            if includeAnchors { anchorFrames.append(NSNull()) }
            if faces.count > 1 { multiple += 1 }
            guard let face = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
                  let lips = face.landmarks?.outerLips, lips.pointCount > 0 else { return }
            found += 1
            let xs = (0..<lips.pointCount).map { Double(lips.normalizedPoints[$0].x) }
            widths.append((xs.max()! - xs.min()!) * Double(face.boundingBox.width) * Double(firstWidth))
            if includeAnchors, let lm = face.landmarks,
               let left = lm.leftEye, let right = lm.rightEye, let nose = lm.nose,
               left.pointCount > 0, right.pointCount > 0, nose.pointCount > 0 {
                func points(_ region: VNFaceLandmarkRegion2D) -> [[Double]] {
                    (0..<region.pointCount).map { i in
                        let p = region.normalizedPoints[i]
                        return [(Double(face.boundingBox.minX) + Double(p.x) * Double(face.boundingBox.width)) * Double(firstWidth),
                                (1 - Double(face.boundingBox.minY) - Double(p.y) * Double(face.boundingBox.height)) * Double(firstHeight)]
                    }
                }
                func mean(_ p: [[Double]]) -> [Double] {
                    [p.map { $0[0] }.reduce(0, +) / Double(p.count), p.map { $0[1] }.reduce(0, +) / Double(p.count)]
                }
                let eyes = [mean(points(left)), mean(points(right))].sorted { $0[0] < $1[0] }
                // Approximation to the reference nose-base anchor; compare accuracy before deployment.
                let base = Array(points(nose).sorted { $0[1] > $1[1] }.prefix(3))
                anchorFrames[anchorFrames.count - 1] = [eyes[0], eyes[1], mean(base), mean(points(lips))]
            }
        }
    }
    if reader.status == .failed { throw reader.error! }
    reader.cancelReading()
    guard !times.isEmpty else { throw NSError(domain: "probe", code: 4, userInfo: [NSLocalizedDescriptionKey: "No decoded frames"]) }
    var result: [String: Any] = [
        "probe": "Apple Vision VNDetectFaceLandmarksRequest, offline, no text recognition",
        "frames": times.count, "frames_with_lips": found, "frames_with_multiple_faces": multiple,
        "width": firstWidth, "height": firstHeight,
        "vision_first_frame_ms": times.first!,
        "vision_warm_p50_ms": percentile(Array(times.dropFirst()), 0.5),
        "vision_warm_p95_ms": percentile(Array(times.dropFirst()), 0.95),
        "mouth_width_pixels_p50": percentile(widths, 0.5),
        "source_frame_gap_ms_p50": percentile(gaps, 0.5) * 1000,
        "total_wall_seconds": CFAbsoluteTimeGetCurrent() - wallStart,
        "camera_started": false, "audio_read": false
    ]
    if includeAnchors { result["anchors_image_xy"] = anchorFrames }
    try emit(result)
}
do { try await run() } catch { fputs("\(error)\n", stderr); exit(1) }
