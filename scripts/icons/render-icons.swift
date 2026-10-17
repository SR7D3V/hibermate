// Renders Hibermate's icons with CoreGraphics (no third-party tools):
//   - AppIcon.appiconset PNGs: a sleeping bear on a night-sky squircle
//   - Menu bar template PDFs: a bear face, asleep (idle) and one eye open (holding)
//
// Usage: swift scripts/icons/render-icons.swift <Assets.xcassets path>

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outline = CGColor(red: 0.10, green: 0.10, blue: 0.16, alpha: 1)
let fur = CGColor(red: 1.0, green: 0.975, blue: 0.94, alpha: 1)

// MARK: - Sleeping bear (full body), drawn in a 1000 × 560 box, y pointing down.

/// The bear's silhouette: head down on the left, rump up on the right.
func bearBody() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 84, y: 362))
    p.addCurve(to: CGPoint(x: 246, y: 282), control1: CGPoint(x: 102, y: 300), control2: CGPoint(x: 176, y: 266))
    p.addCurve(to: CGPoint(x: 600, y: 118), control1: CGPoint(x: 330, y: 220), control2: CGPoint(x: 440, y: 120))
    p.addCurve(to: CGPoint(x: 892, y: 330), control1: CGPoint(x: 762, y: 116), control2: CGPoint(x: 872, y: 196))
    p.addCurve(to: CGPoint(x: 842, y: 484), control1: CGPoint(x: 906, y: 420), control2: CGPoint(x: 884, y: 472))
    p.addLine(to: CGPoint(x: 190, y: 484))
    p.addCurve(to: CGPoint(x: 78, y: 404), control1: CGPoint(x: 128, y: 484), control2: CGPoint(x: 80, y: 452))
    p.addCurve(to: CGPoint(x: 84, y: 362), control1: CGPoint(x: 77, y: 388), control2: CGPoint(x: 79, y: 374))
    p.closeSubpath()
    return p
}

func bearDetails(eyeOpen: Bool) -> (strokes: CGPath, fills: CGPath) {
    let s = CGMutablePath()
    // Ear.
    s.move(to: CGPoint(x: 172, y: 290))
    s.addCurve(to: CGPoint(x: 240, y: 286), control1: CGPoint(x: 166, y: 236), control2: CGPoint(x: 238, y: 232))
    // Tail.
    s.move(to: CGPoint(x: 852, y: 188))
    s.addCurve(to: CGPoint(x: 914, y: 196), control1: CGPoint(x: 864, y: 160), control2: CGPoint(x: 910, y: 162))
    s.addCurve(to: CGPoint(x: 884, y: 236), control1: CGPoint(x: 918, y: 220), control2: CGPoint(x: 902, y: 236))
    // Hind leg (haunch).
    s.move(to: CGPoint(x: 724, y: 226))
    s.addCurve(to: CGPoint(x: 700, y: 478), control1: CGPoint(x: 630, y: 268), control2: CGPoint(x: 618, y: 420))
    // Hind paw.
    s.move(to: CGPoint(x: 700, y: 466))
    s.addCurve(to: CGPoint(x: 790, y: 466), control1: CGPoint(x: 728, y: 452), control2: CGPoint(x: 770, y: 452))
    // Front leg and paw, tucked under the chin.
    s.move(to: CGPoint(x: 360, y: 440))
    s.addCurve(to: CGPoint(x: 492, y: 476), control1: CGPoint(x: 420, y: 444), control2: CGPoint(x: 470, y: 452))
    // Smile.
    s.move(to: CGPoint(x: 104, y: 424))
    s.addQuadCurve(to: CGPoint(x: 140, y: 426), control: CGPoint(x: 120, y: 442))

    let f = CGMutablePath()
    // Nose.
    f.addEllipse(in: CGRect(x: 52, y: 368, width: 48, height: 40))
    if eyeOpen {
        f.addEllipse(in: CGRect(x: 160, y: 340, width: 26, height: 30))
    } else {
        // A closed eye, curved like a sleepy smile.
        s.move(to: CGPoint(x: 150, y: 352))
        s.addQuadCurve(to: CGPoint(x: 196, y: 352), control: CGPoint(x: 173, y: 376))
    }
    return (s, f)
}

func drawBear(_ ctx: CGContext, in rect: CGRect, lineWidth: CGFloat, fill: CGColor?, ink: CGColor, eyeOpen: Bool) {
    ctx.saveGState()
    let scale = min(rect.width / 1000, rect.height / 560)
    ctx.translateBy(x: rect.midX - 500 * scale, y: rect.midY - 300 * scale)
    ctx.scaleBy(x: scale, y: scale)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(lineWidth)
    ctx.setStrokeColor(ink)

    let body = bearBody()
    if let fill {
        ctx.setFillColor(fill)
        ctx.addPath(body)
        ctx.fillPath()
    }
    ctx.addPath(body)
    ctx.strokePath()
    let (strokes, fills) = bearDetails(eyeOpen: eyeOpen)
    ctx.addPath(strokes)
    ctx.strokePath()
    ctx.setFillColor(ink)
    ctx.addPath(fills)
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - App icon

/// macOS icon grid: an 824 pt squircle centred on a 1024 pt canvas.
func renderAppIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in 1024-unit space, y down.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: s / 1024, y: -s / 1024)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow, then the night-sky tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.12, green: 0.15, blue: 0.33, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(red: 0.09, green: 0.11, blue: 0.27, alpha: 1),
        CGColor(red: 0.20, green: 0.22, blue: 0.48, alpha: 1),
        CGColor(red: 0.36, green: 0.33, blue: 0.62, alpha: 1),
    ] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Stars.
    ctx.setFillColor(CGColor(red: 1, green: 0.96, blue: 0.82, alpha: 0.9))
    for (x, y, r) in [(230.0, 230.0, 7.0), (330, 170, 5), (430, 260, 6), (560, 190, 4.5), (300, 330, 4), (480, 360, 3.5)] {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    // Crescent moon (top right): a disc minus an offset disc.
    ctx.saveGState()
    let cutout = CGMutablePath()
    cutout.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    cutout.addEllipse(in: CGRect(x: 712, y: 146, width: 140, height: 140))
    ctx.addPath(cutout)
    ctx.clip(using: .evenOdd)
    ctx.setFillColor(CGColor(red: 1, green: 0.90, blue: 0.62, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 664, y: 170, width: 150, height: 150))
    ctx.restoreGState()

    // A soft hill for the bear to sleep on.
    ctx.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.22, alpha: 0.55))
    ctx.fillEllipse(in: CGRect(x: 60, y: 742, width: 904, height: 300))
    ctx.restoreGState()

    drawBear(ctx, in: CGRect(x: 150, y: 440, width: 724, height: 405), lineWidth: 24, fill: fur, ink: outline, eyeOpen: false)

    // "z z" drifting up from the bear's head.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 0.96, blue: 0.86, alpha: 0.95))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (x, y, w, lw) in [(215.0, 500.0, 46.0, 12.0), (285, 420, 34, 10)] {
        ctx.setLineWidth(lw)
        ctx.move(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x + w, y: y))
        ctx.addLine(to: CGPoint(x: x, y: y + w))
        ctx.addLine(to: CGPoint(x: x + w, y: y + w))
        ctx.strokePath()
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - Menu bar template (bear face), drawn in a 100 × 100 box, y down.

func drawMenuFace(_ ctx: CGContext, eyeOpen: Bool) {
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(7.5)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    // Face.
    let face = CGRect(x: 14, y: 24, width: 72, height: 66)
    ctx.strokeEllipse(in: face)
    // Ears: only the part of each ear circle that lies outside the face, so
    // they sit on the head instead of floating.
    for cx in [25.0, 75.0] {
        let center = CGPoint(x: cx, y: 28), r = 12.0
        var started = false
        for i in 0...360 {
            let a = Double(i) * .pi / 180
            let pt = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            let dx = (pt.x - face.midX) / (face.width / 2), dy = (pt.y - face.midY) / (face.height / 2)
            if dx * dx + dy * dy > 1.0 {
                if started { ctx.addLine(to: pt) } else { ctx.move(to: pt); started = true }
            } else if started {
                ctx.strokePath()
                started = false
            }
        }
        if started { ctx.strokePath() }
    }
    // Left eye: always closed.
    ctx.move(to: CGPoint(x: 30, y: 54))
    ctx.addQuadCurve(to: CGPoint(x: 43, y: 54), control: CGPoint(x: 36.5, y: 61))
    ctx.strokePath()
    // Right eye: closed (idle) or open (holding).
    if eyeOpen {
        ctx.fillEllipse(in: CGRect(x: 58, y: 49, width: 10, height: 11))
    } else {
        ctx.move(to: CGPoint(x: 57, y: 54))
        ctx.addQuadCurve(to: CGPoint(x: 70, y: 54), control: CGPoint(x: 63.5, y: 61))
        ctx.strokePath()
    }
    // Nose.
    ctx.fillEllipse(in: CGRect(x: 43, y: 63, width: 14, height: 10))
}

func writeMenuPDF(to url: URL, eyeOpen: Bool) {
    var box = CGRect(x: 0, y: 0, width: 18, height: 18)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.translateBy(x: 0, y: 18)
    ctx.scaleBy(x: 0.18, y: -0.18)
    drawMenuFace(ctx, eyeOpen: eyeOpen)
    ctx.endPDFPage()
    ctx.closePDF()
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func writeJSON(_ object: Any, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    print("usage: swift render-icons.swift <Assets.xcassets>")
    exit(1)
}
let assets = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
try? fm.createDirectory(at: assets, withIntermediateDirectories: true)
writeJSON(["info": ["author": "xcode", "version": 1]], to: assets.appendingPathComponent("Contents.json"))

// App icon.
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try? fm.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(renderAppIcon(size: pixels), to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], to: iconSet.appendingPathComponent("Contents.json"))

// Menu bar templates.
for (name, eyeOpen) in [("MenuBarSleeping", false), ("MenuBarAwake", true)] {
    let set = assets.appendingPathComponent("\(name).imageset")
    try? fm.createDirectory(at: set, withIntermediateDirectories: true)
    writeMenuPDF(to: set.appendingPathComponent("\(name).pdf"), eyeOpen: eyeOpen)
    writeJSON([
        "images": [["idiom": "universal", "filename": "\(name).pdf"]],
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template", "preserves-vector-representation": true],
    ], to: set.appendingPathComponent("Contents.json"))
}

// A large preview for reviewing the artwork (not shipped).
if let preview = ProcessInfo.processInfo.environment["ICON_PREVIEW"] {
    writePNG(renderAppIcon(size: 1024), to: URL(fileURLWithPath: preview))
}
print("Icons written to \(assets.path)")
