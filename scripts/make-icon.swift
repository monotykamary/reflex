// Draws Reflex's app icon: a dark squircle with the edge tab growing out of
// its right side — a working ring, a waiting dot, a done dot. Flat, no
// gradients. Usage: swift scripts/make-icon.swift <out.png> (1024×1024).
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Squircle body (macOS icon grid: 824 pt body, 100 pt inset).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
color(0x16161a).setFill()
squircle.fill()
color(0xffffff, 0.08).setStroke()
squircle.lineWidth = 4
squircle.stroke()

// The edge tab, flush with the body's right edge, with concave ears.
squircle.addClip()
let w: CGFloat = 210, h: CGFloat = 470, ear: CGFloat = 46, r: CGFloat = 64
let x0 = body.maxX - w, y0 = body.midY - h / 2
let tab = NSBezierPath()
tab.move(to: NSPoint(x: body.maxX, y: y0 + h))
tab.curve(to: NSPoint(x: body.maxX - ear, y: y0 + h - ear), controlPoint1: NSPoint(x: body.maxX, y: y0 + h - ear),
          controlPoint2: NSPoint(x: body.maxX, y: y0 + h - ear))
tab.line(to: NSPoint(x: x0 + r, y: y0 + h - ear))
tab.curve(to: NSPoint(x: x0, y: y0 + h - ear - r), controlPoint1: NSPoint(x: x0, y: y0 + h - ear), controlPoint2: NSPoint(x: x0, y: y0 + h - ear))
tab.line(to: NSPoint(x: x0, y: y0 + ear + r))
tab.curve(to: NSPoint(x: x0 + r, y: y0 + ear), controlPoint1: NSPoint(x: x0, y: y0 + ear), controlPoint2: NSPoint(x: x0, y: y0 + ear))
tab.line(to: NSPoint(x: body.maxX - ear, y: y0 + ear))
tab.curve(to: NSPoint(x: body.maxX, y: y0), controlPoint1: NSPoint(x: body.maxX, y: y0 + ear), controlPoint2: NSPoint(x: body.maxX, y: y0 + ear))
tab.close()
NSColor.black.setFill()
tab.fill()

let cx = x0 + (w - ear) / 2 + 6
// Working: a ring with a gap.
let ring = NSBezierPath()
ring.appendArc(withCenter: NSPoint(x: cx, y: body.midY + 120), radius: 46, startAngle: 120, endAngle: 380)
ring.lineWidth = 17
ring.lineCapStyle = .round
color(0x5c8cff).setStroke()
ring.stroke()
// Waiting and done.
color(0xffb021).setFill()
NSBezierPath(ovalIn: NSRect(x: cx - 34, y: body.midY - 34, width: 68, height: 68)).fill()
color(0x40d187).setFill()
NSBezierPath(ovalIn: NSRect(x: cx - 34, y: body.midY - 154, width: 68, height: 68)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
