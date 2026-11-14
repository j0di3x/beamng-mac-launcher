// Draws the app icon (a steering wheel on an orange tile) and writes Resources/AppIcon.icns.
// Run: swift Tools/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 1.0, green: 0.55, blue: 0.16, alpha: 1),
                        NSColor(red: 0.86, green: 0.27, blue: 0.05, alpha: 1)])!.draw(in: path, angle: -90)

    NSColor(white: 1, alpha: 0.96).setStroke()
    NSColor(white: 1, alpha: 0.96).setFill()
    let c = NSPoint(x: 512 * s, y: 500 * s)
    let rim = NSBezierPath(ovalIn: NSRect(x: c.x - 270 * s, y: c.y - 270 * s, width: 540 * s, height: 540 * s))
    rim.lineWidth = 70 * s; rim.stroke()
    let hub = NSBezierPath(ovalIn: NSRect(x: c.x - 75 * s, y: c.y - 75 * s, width: 150 * s, height: 150 * s))
    hub.fill()
    for (dx, dy) in [(-1.0, 0.18), (1.0, 0.18), (0.0, -1.0)] {
        let spoke = NSBezierPath()
        spoke.move(to: c)
        spoke.line(to: NSPoint(x: c.x + CGFloat(dx) * 250 * s, y: c.y + CGFloat(dy) * 250 * s))
        spoke.lineWidth = 62 * s; spoke.lineCapStyle = .round; spoke.stroke()
    }
    img.unlockFocus()
    return img
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(data: render(px).tiffRepresentation!)!
        rep.size = NSSize(width: px, height: px)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
print("Wrote \(out.path)")
