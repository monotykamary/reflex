// Draws Reflex's app icon: a lazy bot. A light pebble floats on a graphite
// squircle, tilted, its face turned up and to the right — two horizontal slit
// eyes (- -), the near one larger and lower, the far one smaller and higher,
// along a gentle roll. Usage: swift scripts/make-icon.swift <out.png> (1024×1024).
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func shadowed(blur: CGFloat, y: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: y)
    s.shadowColor = NSColor.black.withAlphaComponent(alpha)
    s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The squircle (macOS icon grid: 824 pt body, 100 pt inset), graphite.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
NSGradient(starting: color(0x23252b), ending: color(0x0b0c0f))!.draw(in: squircle, angle: -90)
squircle.addClip()

// The pebble: rounder at the bottom than the top, turned 10°.
let center = NSPoint(x: 500, y: 480), w: CGFloat = 640, h: CGFloat = 600
NSGraphicsContext.saveGraphicsState()
let turn = NSAffineTransform()
turn.translateX(by: center.x, yBy: center.y)
turn.rotate(byDegrees: 10)
turn.concat()
let r = NSRect(x: -w / 2, y: -h / 2, width: w, height: h)
let pebble = NSBezierPath()
pebble.move(to: NSPoint(x: 0, y: r.maxY))
pebble.curve(to: NSPoint(x: r.maxX, y: r.minY + h * 0.5), controlPoint1: NSPoint(x: w * 0.40, y: r.maxY), controlPoint2: NSPoint(x: r.maxX, y: r.maxY - h * 0.22))
pebble.curve(to: NSPoint(x: 0, y: r.minY), controlPoint1: NSPoint(x: r.maxX, y: r.minY + h * 0.16), controlPoint2: NSPoint(x: w * 0.34, y: r.minY))
pebble.curve(to: NSPoint(x: r.minX, y: r.minY + h * 0.5), controlPoint1: NSPoint(x: -w * 0.34, y: r.minY), controlPoint2: NSPoint(x: r.minX, y: r.minY + h * 0.16))
pebble.curve(to: NSPoint(x: 0, y: r.maxY), controlPoint1: NSPoint(x: r.minX, y: r.maxY - h * 0.22), controlPoint2: NSPoint(x: -w * 0.40, y: r.maxY))
pebble.close()
shadowed(blur: 60, y: -24, alpha: 0.5) { color(0xcfd0d4).setFill(); pebble.fill() }
// Lit from above and right, where it is looking.
let light = NSPoint(x: (600 - center.x) / (w / 2), y: (660 - center.y) / (h / 2))
NSGradient(colors: [color(0xffffff), color(0xcfd0d4), color(0x8e9097)], atLocations: [0, 0.7, 1], colorSpace: .sRGB)!
    .draw(in: pebble, relativeCenterPosition: light)
NSGraphicsContext.restoreGraphicsState()

// The eyes: horizontal slits along the face's roll.
func slit(_ p: NSPoint, _ length: CGFloat, _ thickness: CGFloat, _ degrees: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: p.x, yBy: p.y)
    t.rotate(byDegrees: degrees)
    t.concat()
    let path = NSBezierPath(roundedRect: NSRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness),
                            xRadius: thickness / 2, yRadius: thickness / 2)
    shadowed(blur: 6, y: -3, alpha: 0.25) { color(0x141519).setFill(); path.fill() }
    NSGraphicsContext.restoreGraphicsState()
}
let near = NSPoint(x: 530, y: 548), far = NSPoint(x: 718, y: 594)
let roll = atan2(far.y - near.y, far.x - near.x) * 180 / .pi
slit(near, 153, 52, roll)
slit(far, 126, 45, roll)

NSGraphicsContext.restoreGraphicsState()
// The hairline every macOS icon has.
color(0xffffff, 0.08).setStroke()
squircle.lineWidth = 4
squircle.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
