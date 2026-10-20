// Draws the DMG window background: a heading, an arrow from Hibermate to
// Applications, and the first-launch steps for unsigned builds.
//
// Usage: swift scripts/dmg/render-background.swift <output-dir>
// Writes background.png (760x520) and background@2x.png (1520x1040).
// The window shows about 660x420 of it, but newer Finder versions make the
// content area a little bigger, so the gradient extends past the design to
// leave no uncovered edges. The icon positions here must match scripts/build-dmg.sh.

import AppKit
import Foundation

let width: CGFloat = 760, height: CGFloat = 520
/// The designed area (top-left aligned with the window); text centers on it.
let designWidth: CGFloat = 660
let appIconCenter = CGPoint(x: 165, y: 190)
let applicationsCenter = CGPoint(x: 495, y: 190)

let ink = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.17, alpha: 1)
let secondaryInk = NSColor(srgbRed: 0.36, green: 0.38, blue: 0.46, alpha: 1)
let accent = NSColor(srgbRed: 0.36, green: 0.36, blue: 0.80, alpha: 1)

func draw(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    // Work top-down, like the Finder window.
    let cg = context.cgContext
    cg.translateBy(x: 0, y: height)
    cg.scaleBy(x: 1, y: -1)

    // Soft light background.
    let gradient = NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.97, blue: 0.99, alpha: 1),
                                       NSColor(srgbRed: 0.91, green: 0.92, blue: 0.96, alpha: 1)])!
    // The gradient ends (bottom of the design) in this color; it fills the rest.
    cg.setFillColor(NSColor(srgbRed: 0.91, green: 0.92, blue: 0.96, alpha: 1).cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
    gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: 420), angle: 90)

    func text(_ string: String, _ font: NSFont, _ color: NSColor, centeredAt y: CGFloat, maxWidth: CGFloat = 580) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let bounds = attributed.boundingRect(with: NSSize(width: maxWidth, height: 200), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.saveGraphicsState()
        // Text drawing needs an unflipped context.
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current = flipped
        attributed.draw(with: NSRect(x: (designWidth - maxWidth) / 2, y: y - bounds.height / 2, width: maxWidth, height: bounds.height + 4),
                        options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    text("Install Hibermate", .systemFont(ofSize: 22, weight: .semibold), ink, centeredAt: 42)
    text("Drag Hibermate into your Applications folder.", .systemFont(ofSize: 13), secondaryInk, centeredAt: 72)

    // Arrow from the app icon to Applications.
    let y = appIconCenter.y - 4
    let start = appIconCenter.x + 80, end = applicationsCenter.x - 80
    cg.setStrokeColor(accent.cgColor)
    cg.setLineWidth(5)
    cg.setLineCap(.round)
    cg.move(to: CGPoint(x: start, y: y))
    cg.addLine(to: CGPoint(x: end - 4, y: y))
    cg.strokePath()
    cg.setFillColor(accent.cgColor)
    cg.move(to: CGPoint(x: end + 8, y: y))
    cg.addLine(to: CGPoint(x: end - 14, y: y - 13))
    cg.addLine(to: CGPoint(x: end - 14, y: y + 13))
    cg.closePath()
    cg.fillPath()

    // First-launch steps.
    let panel = CGRect(x: 40, y: 292, width: designWidth - 80, height: 104)
    cg.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    cg.addPath(CGPath(roundedRect: panel, cornerWidth: 14, cornerHeight: 14, transform: nil))
    cg.fillPath()
    cg.setStrokeColor(NSColor.black.withAlphaComponent(0.06).cgColor)
    cg.setLineWidth(1)
    cg.addPath(CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 14, cornerHeight: 14, transform: nil))
    cg.strokePath()
    text("Then open Hibermate from Applications.", .systemFont(ofSize: 13, weight: .semibold), ink, centeredAt: 316)
    text("If macOS says \u{201C}Hibermate\u{201D} Not Opened, click Done, then go to",
         .systemFont(ofSize: 12.5), secondaryInk, centeredAt: 344)
    text("System Settings \u{2192} Privacy & Security \u{2192} Open Anyway.",
         .systemFont(ofSize: 12.5, weight: .semibold), ink, centeredAt: 366)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try draw(scale: 1).write(to: out.appendingPathComponent("background.png"))
try draw(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
print("DMG background written to \(out.path)")
