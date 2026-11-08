// Per-frame face geometry from a camera.mov, with Apple Vision, offline. Writes landmarks.csv next to the video.
// Usage: landmarks <session-folder> [...]
import AVFoundation
import Foundation
import Vision

func run(_ dir: String) throws {
    let url = URL(fileURLWithPath: dir).appendingPathComponent("camera.mov")
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else { print("no video in \(dir)"); return }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out); reader.startReading()
    var rows = "frame,ok,face_x,face_y,face_w,face_h,lip_gap,lip_w,jaw,nose_x,nose_y,yaw,pitch,roll\n", i = 0
    while let sb = out.copyNextSampleBuffer() {
        defer { i += 1 }
        guard let px = CMSampleBufferGetImageBuffer(sb) else { continue }
        let w = Double(CVPixelBufferGetWidth(px)), h = Double(CVPixelBufferGetHeight(px))
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, options: [:]).perform([req])
        guard let f = req.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }), let lm = f.landmarks,
              let inner = lm.innerLips, let outer = lm.outerLips, let nose = lm.nose, let contour = lm.faceContour else { rows += "\(i),0,,,,,,,,,,,,\n"; continue }
        let pts = { (r: VNFaceLandmarkRegion2D) in r.pointsInImage(imageSize: CGSize(width: w, height: h)) }
        let ip = pts(inner), op = pts(outer), np = pts(nose), cp = pts(contour)
        let gap = Double((ip.map(\.y).max() ?? 0)-(ip.map(\.y).min() ?? 0))
        let lipW = Double((op.map(\.x).max() ?? 0)-(op.map(\.x).min() ?? 0))
        let noseX = np.map { Double($0.x) }.reduce(0, +)/Double(np.count), noseY = np.map { Double($0.y) }.reduce(0, +)/Double(np.count)
        let jaw = noseY-Double(cp.map(\.y).min() ?? 0)
        let b = f.boundingBox
        rows += "\(i),1,\(b.minX*w),\(b.minY*h),\(b.width*w),\(b.height*h),\(gap),\(lipW),\(jaw),\(noseX),\(noseY),\(f.yaw?.doubleValue ?? 0),\(f.pitch?.doubleValue ?? 0),\(f.roll?.doubleValue ?? 0)\n"
    }
    try rows.write(to: URL(fileURLWithPath: dir).appendingPathComponent("landmarks.csv"), atomically: true, encoding: .utf8)
    print("\(dir): \(i) frames")
}
for d in CommandLine.arguments.dropFirst() { try run(d) }
