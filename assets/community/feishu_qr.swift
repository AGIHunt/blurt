// Regenerates feishu-group-qr.png, the join QR code for the Blurt users' Feishu group.
// Run from the repo root: swift assets/community/feishu_qr.swift
// The link is the group's permanent share link (group settings → 群二维码 → 永久有效).
import AppKit
import CoreImage

let link = "https://applink.feishu.cn/client/chat/chatter/add_by_link?link_token=55ame8f2-6482-400c-84b2-06de3ea29cb2&qr_code=true"
let out = "assets/community/feishu-group-qr.png"

let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(link.data(using: .utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
let code = filter.outputImage!
// Whole-pixel modules, with a quiet zone of 4 modules on each side.
let scale: CGFloat = 10
let sized = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
let pad = 4 * scale
let canvas = CGRect(x: 0, y: 0, width: sized.extent.width + 2 * pad, height: sized.extent.height + 2 * pad)
let image = sized.transformed(by: CGAffineTransform(translationX: pad, y: pad))
    .composited(over: CIImage(color: .white).cropped(to: canvas))
let rep = NSBitmapImageRep(ciImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(Int(canvas.width))×\(Int(canvas.height)))")
