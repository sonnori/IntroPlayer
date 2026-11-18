import AppKit
import Foundation

// Fits artwork into the macOS icon grid: the picture does NOT go edge to edge — it sits in a
// rounded square that fills about 80% of the canvas, with transparent margin around it. Skipping
// this is why hand-made icons look oversized next to Apple's in the Dock.
//
//   makeicon <input.png> <output.png> [--full]
//     default : scale to fit the 824/1024 rounded square and mask the corners
//     --full  : use the image as-is (already shaped, transparent background)

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: makeicon <in.png> <out.png> [--full]\n".data(using: .utf8)!)
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let full = args.contains("--full")

guard let src = NSImage(contentsOf: inURL) else {
    FileHandle.standardError.write("อ่านรูปไม่ได้: \(inURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let S: CGFloat = 1024
let inset: CGFloat = full ? 0 : 100          // 824 of 1024, Apple's proportion
let radius: CGFloat = 185                    // matches the macOS squircle closely enough

guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write("สร้าง canvas ไม่ได้\n".data(using: .utf8)!); exit(1)
}
ctx.interpolationQuality = .high

var rect = CGRect(x: 0, y: 0, width: S, height: S)
guard var cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
    FileHandle.standardError.write("แปลงรูปไม่ได้\n".data(using: .utf8)!); exit(1)
}

let box = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
if !full {
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
}

// aspect-fill the box so a non-square source is cropped rather than squashed
let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
let scale = max(box.width / iw, box.height / ih)
let dw = iw * scale, dh = ih * scale
let draw = CGRect(x: box.midX - dw / 2, y: box.midY - dh / 2, width: dw, height: dh)
ctx.draw(cg, in: draw)

guard let out = ctx.makeImage() else { exit(1) }
cg = out
let rep = NSBitmapImageRep(cgImage: cg)
rep.size = NSSize(width: S, height: S)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: outURL)
print("wrote \(outURL.lastPathComponent) (1024×1024\(full ? ", ใช้รูปเต็ม" : ", ใส่ขอบมนให้แล้ว"))")
