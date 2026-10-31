// Renders Murmur's app icon: a murmuration of starlings, a twisting flock moving as one, against a dusk sky.
// Usage: swift Scripts/make-icon.swift <output.png> [size]
// Scripts/make-icon.sh turns the PNG into Resources/AppIcon.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon.png"
let size = args.count > 2 ? Int(args[2]) ?? 1024 : 1024
let s = CGFloat(size) / 1024 // all coordinates below are on a 1024 grid

/// Deterministic RNG so the icon is reproducible.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
var rng = SplitMix(state: 0x6D75_726D_7572) // "murmur"
func rand(_ r: ClosedRange<CGFloat> = 0...1) -> CGFloat { CGFloat.random(in: r, using: &rng) }
func gaussian() -> CGFloat {
    let u = max(rand(), 1e-9), v = rand()
    return sqrt(-2 * log(u)) * cos(2 * CGFloat.pi * v)
}

let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: s, y: s)
// Flip so y grows downward like a design canvas.
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a,
    ])!
}

// macOS icon grid: 824×824 body centered in the 1024 canvas, continuous-ish corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: color(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0x1A1C45))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Dusk sky: deep indigo → violet → rose → warm amber at the horizon.
let sky = CGGradient(colorsSpace: space, colors: [
    color(0x141A44), color(0x3B2C6E), color(0xB0517A), color(0xF3955C), color(0xFFC77D),
] as CFArray, locations: [0, 0.38, 0.68, 0.88, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

// Low sun glow.
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFE2A8, 0.85), color(0xFFB36B, 0.0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 640, y: 930), startRadius: 0,
                       endCenter: CGPoint(x: 640, y: 930), endRadius: 420, options: [])

// Distant hills.
ctx.setFillColor(color(0x5B3560, 0.55))
ctx.move(to: CGPoint(x: 100, y: 860))
ctx.addCurve(to: CGPoint(x: 520, y: 840), control1: CGPoint(x: 230, y: 815), control2: CGPoint(x: 380, y: 860))
ctx.addCurve(to: CGPoint(x: 924, y: 830), control1: CGPoint(x: 680, y: 818), control2: CGPoint(x: 820, y: 800))
ctx.addLine(to: CGPoint(x: 924, y: 924))
ctx.addLine(to: CGPoint(x: 100, y: 924))
ctx.fillPath()
ctx.setFillColor(color(0x1C1230, 0.85))
ctx.move(to: CGPoint(x: 100, y: 892))
ctx.addCurve(to: CGPoint(x: 560, y: 880), control1: CGPoint(x: 260, y: 860), control2: CGPoint(x: 420, y: 900))
ctx.addCurve(to: CGPoint(x: 924, y: 872), control1: CGPoint(x: 700, y: 862), control2: CGPoint(x: 830, y: 850))
ctx.addLine(to: CGPoint(x: 924, y: 924))
ctx.addLine(to: CGPoint(x: 100, y: 924))
ctx.fillPath()

// The murmuration: a ribbon that twists in space. Where it twists, its projected width shrinks and the birds
// crowd together (darker); where it faces us it fans out (lighter), the classic look of a starling flock.
func center(_ t: CGFloat) -> CGPoint {
    CGPoint(x: 235 + 555 * t,
            y: 470 + 110 * sin(CGFloat.pi * 2 * 0.9 * t + 0.6) - 60 * (t - 0.5))
}
func halfWidth(_ t: CGFloat) -> CGFloat {
    let envelope = pow(sin(CGFloat.pi * min(max(t, 0), 1)), 0.7)    // tapers at both ends
    let twist = 0.16 + 0.84 * abs(cos(CGFloat.pi * (1.9 * t + 0.15))) // ribbon twisting
    return 14 + 112 * envelope * twist
}

let birdColor = color(0x0E0B1A)
let birds = 11_000
for _ in 0..<birds {
    let t = pow(rand(), 0.95)
    let p = center(t)
    let q = center(min(t + 0.001, 1))
    var nx = -(q.y - p.y), ny = q.x - p.x
    let len = max(sqrt(nx * nx + ny * ny), 1e-6)
    nx /= len; ny /= len
    let across = gaussian() * 0.42 * halfWidth(t)
    let along = gaussian() * 6
    let x = p.x + nx * across + along
    let y = p.y + ny * across
    let r = 1.1 + rand() * 1.5
    ctx.setFillColor(birdColor.copy(alpha: 0.55 + rand() * 0.4)!)
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r * 0.8, width: r * 2, height: r * 1.6))
}

// A few stragglers around the flock.
for _ in 0..<70 {
    let t = rand()
    let p = center(t)
    let x = p.x + gaussian() * 60
    let y = p.y + gaussian() * 70
    // Tiny "v" wing shapes for the loose birds.
    let w = 3 + rand() * 3
    ctx.setStrokeColor(birdColor.copy(alpha: 0.75)!)
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: x - w, y: y - w * 0.5))
    ctx.addLine(to: CGPoint(x: x, y: y))
    ctx.addLine(to: CGPoint(x: x + w, y: y - w * 0.5))
    ctx.strokePath()
}

// Subtle top highlight for depth.
let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 420), options: [])
ctx.restoreGState()

// Hairline edge.
ctx.addPath(shape)
ctx.setStrokeColor(color(0xFFFFFF, 0.12))
ctx.setLineWidth(2)
ctx.strokePath()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: outPath) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(outPath)") }
print("Wrote \(outPath) (\(size)×\(size))")
