// Renders the Seethru app icon (AppIcon.icns) and docs/logo.svg from one set of numbers.
// Concept: two windows, the front one see-through. Flat shapes, real alpha, no gradients/glow/shadow.
// Usage: swift scripts/make_icon.swift   (run from the repo root)
import AppKit
import Foundation

struct Rect { var x, y, w, h: Double }
let canvas = 1024.0
let body = Rect(x: 100, y: 100, w: 824, h: 824), bodyR = 185.0
let back = Rect(x: 236, y: 262, w: 420, h: 340), front = Rect(x: 368, y: 400, w: 420, h: 340), winR = 44.0, band = 78.0
let ground = (0x10, 0x1B, 0x20), paper = (0xEC, 0xF0, 0xEE), paperBand = (0xC9, 0xD3, 0xD0), accent = (0x1F, 0xBF, 0x9E)
let frontAlpha = 0.58, frontBandAlpha = 0.80

func ns(_ c: (Int, Int, Int), _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255, alpha: a)
}
func hex(_ c: (Int, Int, Int)) -> String { String(format: "#%02X%02X%02X", c.0, c.1, c.2) }

func rr(_ r: Rect, _ radius: Double, size: Double) -> NSBezierPath {
    let s = size / canvas
    // y-down design space -> AppKit y-up
    let rect = NSRect(x: r.x * s, y: (canvas - r.y - r.h) * s, width: r.w * s, height: r.h * s)
    return NSBezierPath(roundedRect: rect, xRadius: radius * s, yRadius: radius * s)
}

func draw(size: Double) {
    let s = size / canvas
    ns(ground).setFill(); rr(body, bodyR, size: size).fill()
    func window(_ r: Rect, fill: NSColor, band bandColor: NSColor) {
        let path = rr(r, winR, size: size)
        fill.setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        bandColor.setFill()
        NSRect(x: r.x * s, y: (canvas - r.y - band) * s, width: r.w * s, height: band * s).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    window(back, fill: ns(paper), band: ns(paperBand))
    // Front window: one flat colour at partial alpha, so the ground and the back window show through.
    let path = rr(front, winR, size: size)
    ns(accent, frontAlpha).setFill(); path.fill()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    ns(accent, frontBandAlpha - frontAlpha).setFill()
    NSRect(x: front.x * s, y: (canvas - front.y - band) * s, width: front.w * s, height: band * s).fill()
    NSGraphicsContext.restoreGraphicsState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(size: Double(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "Resources/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try png(size: px).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
try? fm.removeItem(atPath: iconset)
try png(size: 1024).write(to: URL(fileURLWithPath: "docs/logo.png"))

func svgRect(_ r: Rect, _ radius: Double, _ extra: String) -> String {
    "<rect x=\"\(r.x)\" y=\"\(r.y)\" width=\"\(r.w)\" height=\"\(r.h)\" rx=\"\(radius)\" \(extra)/>"
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="512" height="512" role="img" aria-label="Seethru">
  <defs>
    <clipPath id="b">\(svgRect(back, winR, ""))</clipPath>
    <clipPath id="f">\(svgRect(front, winR, ""))</clipPath>
  </defs>
  \(svgRect(body, bodyR, "fill=\"\(hex(ground))\""))
  \(svgRect(back, winR, "fill=\"\(hex(paper))\""))
  <rect x="\(back.x)" y="\(back.y)" width="\(back.w)" height="\(band)" fill="\(hex(paperBand))" clip-path="url(#b)"/>
  \(svgRect(front, winR, "fill=\"\(hex(accent))\" fill-opacity=\"\(frontAlpha)\""))
  <rect x="\(front.x)" y="\(front.y)" width="\(front.w)" height="\(band)" fill="\(hex(accent))" fill-opacity="\(frontBandAlpha - frontAlpha)" clip-path="url(#f)"/>
</svg>
"""
try svg.write(toFile: "docs/logo.svg", atomically: true, encoding: .utf8)
print("ok")
