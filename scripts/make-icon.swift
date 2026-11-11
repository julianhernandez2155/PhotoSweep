// Draws the app icon as a 1024px PNG. Usage: swift scripts/make-icon.swift <output.png>
// Only needed if you want to change the icon; the built AppIcon.icns lives in Support/.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext

// Background tile.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
context.saveGState()
context.addPath(tilePath)
context.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.13, green: 0.14, blue: 0.20, alpha: 1),
        CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1),
    ] as CFArray, locations: [0, 1])!
context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
context.restoreGState()

func card(center: CGPoint, angle: CGFloat, fill: CGColor, symbol: String?, tint: NSColor) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: angle * .pi / 180)
    let rect = CGRect(x: -190, y: -250, width: 380, height: 500)
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: CGColor(gray: 0, alpha: 0.5))
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 54, cornerHeight: 54, transform: nil))
    context.setFillColor(fill)
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    if let symbol,
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 210, weight: .bold))
    {
        let tinted = NSImage(size: image.size, flipped: false) { bounds in
            image.draw(in: bounds)
            tint.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        tinted.draw(in: CGRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height))
    }
    context.restoreGState()
}

card(
    center: CGPoint(x: 410, y: 500), angle: 13,
    fill: CGColor(red: 0.93, green: 0.27, blue: 0.30, alpha: 1), symbol: "xmark", tint: .white)
card(
    center: CGPoint(x: 600, y: 512), angle: -9,
    fill: CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1), symbol: "checkmark",
    tint: NSColor(red: 0.16, green: 0.72, blue: 0.42, alpha: 1))

try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
