// Draws Resources/AppIcon.icns from scratch: a dark instrument-panel squircle with
// a rising sparkline, the same shape the panel draws. Regenerate with:
//
//     swift Tools/make-icon.swift
//
// Every size is drawn at its own resolution rather than downsampled from 1024, so
// the 16pt menu-bar-scale icon stays crisp. Nothing here ships in the app; it just
// produces the .icns that build-app.sh copies into the bundle.

import AppKit

// MARK: - Apple's continuous ("squircle") corner

/// Rounded rect with iOS/macOS continuous corners. Circular corners read visibly
/// wrong next to system icons; these are the standard smoothing coefficients, laid
/// out per corner as offsets along the two edges meeting there.
func squirclePath(in rect: CGRect, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let (l, b, t2, rt) = (rect.minX, rect.minY, rect.maxY, rect.maxX)

    // Each corner: the point, plus unit vectors along the incoming and outgoing edges.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: l,  y: b),  CGVector(dx: 0, dy:  1), CGVector(dx:  1, dy: 0)),
        (CGPoint(x: rt, y: b),  CGVector(dx: 1, dy:  0).negated, CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rt, y: t2), CGVector(dx: 0, dy:  1).negated, CGVector(dx: 1, dy: 0).negated),
        (CGPoint(x: l,  y: t2), CGVector(dx: 1, dy:  0), CGVector(dx: 0, dy: 1).negated),
    ]

    func at(_ p: CGPoint, _ u: CGVector, _ a: CGFloat, _ v: CGVector, _ b: CGFloat) -> CGPoint {
        CGPoint(x: p.x + u.dx * a * r + v.dx * b * r,
                y: p.y + u.dy * a * r + v.dy * b * r)
    }

    for (i, (p, u, v)) in corners.enumerated() {
        let start = at(p, u, 1.528665, v, 0)
        if i == 0 { path.move(to: start) } else { path.addLine(to: start) }
        path.addCurve(to: at(p, u, 0.631494, v, 0.074911),
                      control1: at(p, u, 1.088484, v, 0),
                      control2: at(p, u, 0.868407, v, 0))
        path.addCurve(to: at(p, u, 0.074911, v, 0.631494),
                      control1: at(p, u, 0.372824, v, 0.169060),
                      control2: at(p, u, 0.169060, v, 0.372824))
        path.addCurve(to: at(p, u, 0, v, 1.528665),
                      control1: at(p, u, 0, v, 0.868407),
                      control2: at(p, u, 0, v, 1.088484))
    }
    path.closeSubpath()
    return path
}

extension CGVector { var negated: CGVector { CGVector(dx: -dx, dy: -dy) } }

// MARK: - Palette

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let bgTop    = rgb(44, 51, 68)
let bgBottom = rgb(13, 15, 23)
let accentA  = rgb(107, 245, 154)   // green, low end of the line
let accentB  = rgb(61, 220, 245)    // cyan, high end

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors as CFArray, locations: locations)!
}

// MARK: - The icon

/// Normalised sparkline, sampled left to right. Straight segments with round joins
/// read as an instrument trace and survive downscaling better than a smooth spline.
let trace: [CGFloat] = [0.30, 0.13, 0.46, 0.30, 0.55, 0.40, 0.74, 1.0]

func drawIcon(size S: CGFloat, into ctx: CGContext) {
    let k = S / 1024                       // every constant below is in 1024-space
    func s(_ v: CGFloat) -> CGFloat { v * k }

    // Apple's icon grid: an 824pt body centred in a 1024pt canvas.
    let body = CGRect(x: s(100), y: s(100), width: s(824), height: s(824))
    let shape = squirclePath(in: body, radius: s(185.4))

    // Contact shadow, so the icon sits on the Dock rather than floating.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s(-10)), blur: s(24),
                  color: rgb(0, 0, 0, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(bgBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    ctx.drawLinearGradient(gradient([bgTop, bgBottom], [0, 1]),
                           start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY),
                           options: [])

    // Chart area, inset inside the body.
    let chart = body.insetBy(dx: s(120), dy: s(250))

    // Grid. Pure texture — omitted at sizes where it would only add noise.
    if S >= 64 {
        ctx.setStrokeColor(rgb(255, 255, 255, 0.07))
        ctx.setLineWidth(s(4))
        for i in 1...3 {
            let y = chart.minY + chart.height * CGFloat(i) / 4
            ctx.move(to: CGPoint(x: chart.minX, y: y))
            ctx.addLine(to: CGPoint(x: chart.maxX, y: y))
        }
        ctx.strokePath()
    }

    let points = trace.enumerated().map { i, v in
        CGPoint(x: chart.minX + chart.width * CGFloat(i) / CGFloat(trace.count - 1),
                y: chart.minY + chart.height * v)
    }

    // The trace itself, stroked wide enough to hold up at menu-bar scale.
    let line = CGMutablePath()
    line.addLines(between: points)
    let stroked = line.copy(strokingWithWidth: s(74), lineCap: .round,
                            lineJoin: .round, miterLimit: 10)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s(40), color: rgb(80, 230, 190, 0.55))
    ctx.addPath(stroked)
    ctx.setFillColor(accentA)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(stroked)
    ctx.clip()
    ctx.drawLinearGradient(gradient([accentA, accentB], [0, 1]),
                           start: CGPoint(x: chart.minX, y: 0),
                           end: CGPoint(x: chart.maxX, y: 0), options: [])
    ctx.restoreGState()

    // Highlight on the leading peak.
    if S >= 32 {
        let peak = points.last!
        ctx.setFillColor(rgb(224, 255, 240))
        ctx.fillEllipse(in: CGRect(x: peak.x - s(46), y: peak.y - s(46),
                                   width: s(92), height: s(92)))
    }

    // Top-edge light, the standard macOS icon depth cue.
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.16))
    ctx.setLineWidth(s(6))
    ctx.strokePath()

    ctx.restoreGState()
}

// MARK: - Render the iconset

func png(size: CGFloat) -> Data {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    drawIcon(size: size, into: gctx.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                  ?? "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try png(size: CGFloat(base * scale)).write(to: iconset.appendingPathComponent(name))
}
print("Wrote \(iconset.path)")
