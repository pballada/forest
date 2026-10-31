#!/usr/bin/env swift
// Renders Forest's app icon into an .iconset and converts it to Resources/AppIcon.icns.
// The icon is a small landscape: dawn sky and sun, misty hills, and three layers of pines that get
// darker and larger towards the front, with light coming from the sun on the left.
// Usage: swift scripts/make-icon.swift <output.icns>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Forest.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// A rolling hill: a smooth curve through `points` (x, y), filled down to the bottom of the icon.
func hill(_ ctx: CGContext, _ points: [(CGFloat, CGFloat)], top: CGColor, bottom: CGColor) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: points[0].0, y: points[0].1))
    for i in 1..<points.count {
        let (x0, y0) = points[i - 1], (x1, y1) = points[i]
        let mid = (x0 + x1) / 2
        path.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: mid, y: y0), control2: CGPoint(x: mid, y: y1))
    }
    path.addLine(to: CGPoint(x: 1024, y: 0))
    path.closeSubpath()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let maxY = points.map(\.1).max() ?? 0
    ctx.drawLinearGradient(gradient([top, bottom], [0, 1]), start: CGPoint(x: 0, y: maxY), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()
}

/// A pine of stacked, slightly drooping tiers. The right half is shaded, away from the sun.
func pine(_ ctx: CGContext, x: CGFloat, base: CGFloat, height: CGFloat, width: CGFloat,
          light: CGColor, dark: CGColor, trunk: CGColor, tiers: Int = 3) {
    let trunkHeight = height * 0.09
    ctx.setFillColor(trunk)
    ctx.fill(CGRect(x: x - width * 0.06, y: base, width: width * 0.12, height: trunkHeight + height * 0.05))

    let crown = CGMutablePath()
    let bodyHeight = height - trunkHeight
    for tier in 0..<tiers {
        let t = CGFloat(tier) / CGFloat(tiers)
        let tierBase = base + trunkHeight + bodyHeight * t * 0.78
        let tierTop = base + trunkHeight + bodyHeight * (0.42 + t * 0.58)
        let half = width / 2 * (1 - t * 0.52)
        let droop = height * 0.035
        crown.move(to: CGPoint(x: x, y: tierTop))
        crown.addQuadCurve(to: CGPoint(x: x - half, y: tierBase), control: CGPoint(x: x - half * 0.35, y: tierBase + (tierTop - tierBase) * 0.35))
        crown.addQuadCurve(to: CGPoint(x: x + half, y: tierBase), control: CGPoint(x: x, y: tierBase - droop))
        crown.addQuadCurve(to: CGPoint(x: x, y: tierTop), control: CGPoint(x: x + half * 0.35, y: tierBase + (tierTop - tierBase) * 0.35))
        crown.closeSubpath()
    }
    ctx.addPath(crown)
    ctx.setFillColor(light)
    ctx.fillPath()

    ctx.saveGState()
    ctx.addPath(crown)
    ctx.clip()
    ctx.setFillColor(dark)
    ctx.fill(CGRect(x: x, y: base, width: width, height: height * 1.1))
    ctx.restoreGState()
}

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: 824/1024 body with a soft shadow.
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let radius = rect.width * 0.225
    let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x0B2A1E, 0.45))
    ctx.addPath(body)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()

    // Dawn sky: fresh mint above, warm light at the horizon.
    ctx.drawLinearGradient(gradient([color(0x8EDBC8), color(0xC9EED3), color(0xFFE7AE)], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 430), options: [.drawsAfterEndLocation])

    // Sun with a wide glow.
    let sun = CGPoint(x: 330, y: 700)
    ctx.drawRadialGradient(gradient([color(0xFFF4C7, 0.95), color(0xFFE29A, 0.45), color(0xFFE29A, 0)], [0, 0.35, 1]),
                           startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 330, options: [])
    ctx.setFillColor(color(0xFFF1BE))
    ctx.fillEllipse(in: CGRect(x: sun.x - 62, y: sun.y - 62, width: 124, height: 124))

    // Two birds heading for the sun.
    ctx.setStrokeColor(color(0x2D5A47, 0.75))
    ctx.setLineWidth(7)
    ctx.setLineCap(.round)
    for (bx, by, w) in [(560.0, 770.0, 46.0), (628, 742, 34)] {
        ctx.move(to: CGPoint(x: bx - w / 2, y: by + w * 0.28))
        ctx.addQuadCurve(to: CGPoint(x: bx, y: by), control: CGPoint(x: bx - w * 0.22, y: by + w * 0.32))
        ctx.addQuadCurve(to: CGPoint(x: bx + w / 2, y: by + w * 0.28), control: CGPoint(x: bx + w * 0.22, y: by + w * 0.32))
        ctx.strokePath()
    }

    // Misty far hills.
    hill(ctx, [(60, 500), (260, 560), (470, 515), (690, 585), (960, 520)], top: color(0xA8D9BD), bottom: color(0xB9E2C6))

    // Back row of small, hazy pines.
    let backLight = color(0x93CFAE), backDark = color(0x82C2A0), backTrunk = color(0x82B597)
    for (x, h) in [(150.0, 170.0), (215, 215), (600, 200), (665, 240), (845, 195), (905, 225)] {
        pine(ctx, x: x, base: 455, height: h, width: h * 0.55, light: backLight, dark: backDark, trunk: backTrunk)
    }

    // Middle hill and pines.
    hill(ctx, [(40, 430), (300, 470), (560, 420), (820, 475), (1000, 440)], top: color(0x6DBA8A), bottom: color(0x5AA97A))
    let midLight = color(0x52AD78), midDark = color(0x43996A), midTrunk = color(0x5E7E64)
    for (x, h) in [(145.0, 300.0), (225, 245), (780, 330), (875, 270)] {
        pine(ctx, x: x, base: 395, height: h, width: h * 0.52, light: midLight, dark: midDark, trunk: midTrunk)
    }

    // Foreground: the hero pine and its neighbours on a dark, sunlit meadow.
    hill(ctx, [(20, 300), (240, 345), (520, 300), (780, 350), (1010, 310)], top: color(0x2E8A52), bottom: color(0x17573A))
    let frontLight = color(0x1E7A45), frontDark = color(0x125A32), frontTrunk = color(0x5B3F2C)
    pine(ctx, x: 335, base: 255, height: 420, width: 230, light: frontLight, dark: frontDark, trunk: frontTrunk)
    pine(ctx, x: 690, base: 265, height: 390, width: 215, light: frontLight, dark: frontDark, trunk: frontTrunk)
    pine(ctx, x: 515, base: 205, height: 600, width: 320, light: color(0x1C8649), dark: color(0x0F5E33), trunk: frontTrunk, tiers: 4)

    // Ground fog line and a soft vignette for depth.
    ctx.drawLinearGradient(gradient([color(0x0E3B28, 0), color(0x0E3B28, 0.45)], [0, 1]),
                           start: CGPoint(x: 0, y: 330), end: CGPoint(x: 0, y: 100), options: [])
    // Glassy highlight across the top.
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 690), options: [])
    ctx.restoreGState()

    // Hairline edge so the icon holds up on light and dark docks.
    ctx.addPath(body)
    ctx.setStrokeColor(color(0xFFFFFF, 0.18))
    ctx.setLineWidth(2)
    ctx.strokePath()

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
