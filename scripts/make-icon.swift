#!/usr/bin/env swift
// Renders Forest's app icon into an .iconset and converts it to Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift <output.icns>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Forest.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = size * 100 / 1024
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(body)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let colors = [NSColor(red: 0.20, green: 0.80, blue: 0.56, alpha: 1).cgColor,
                  NSColor(red: 0.05, green: 0.42, blue: 0.50, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Glossy top highlight.
    let shine = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.30).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    // Tree glyph.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.36, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "tree.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = symbol.size
        let target = CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2 + size * 0.01, width: s.width, height: s.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.025, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        symbol.draw(in: target)
        ctx.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
try? render(1024).write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))
print(process.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
