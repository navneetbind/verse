// Draws the Verse app icon and builds Resources/AppIcon.icns.
// Run from menubar/: swift scripts/make_icon.swift
import AppKit

let size: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Apple's macOS icon grid: 824pt body centred on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(squircle); ctx.setFillColor(rgb(0x2A1B4D)); ctx.fillPath()
ctx.restoreGState()

// Night-sky body: plum at the top to deep indigo at the bottom
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let gradient = CGGradient(colorsSpace: cs, colors: [rgb(0x7B3FA0), rgb(0x3C2A7A), rgb(0x161B44)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 80), options: [])
ctx.restoreGState()

// Music note (SF Symbol), white, upper half
let cfg = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    var rect = CGRect(x: 0, y: 0, width: note.size.width, height: note.size.height)
    if let cg = note.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
        let w = note.size.width, h = note.size.height
        let r = CGRect(x: (size - w) / 2, y: 470, width: w, height: h)
        ctx.saveGState()
        ctx.clip(to: r, mask: cg)
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(r)
        ctx.restoreGState()
    }
}

// Two lyric lines; one word lit yellow, like the menu bar highlight
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ color: CGColor) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: 50), cornerWidth: 25, cornerHeight: 25, transform: nil))
    ctx.setFillColor(color); ctx.fillPath()
}
bar(250, 360, 170, rgb(0xFFFFFF, 0.92))
bar(440, 360, 150, rgb(0xFFD54A))
bar(610, 360, 164, rgb(0xFFFFFF, 0.92))
bar(320, 270, 384, rgb(0xFFFFFF, 0.38))

// Write the 1024 master + iconset + icns
let fm = FileManager.default
let master = URL(fileURLWithPath: "Resources/AppIcon-1024.png")
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: master)

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run(); iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
