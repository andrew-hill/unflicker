// Draws the app icon and writes an AppIcon.appiconset. Output is deterministic,
// so a rerun should leave the committed PNGs untouched.
//
//     swift make-icon.swift <path to Assets.xcassets>
//
// The mark is a monitor showing a video call with mains banding across the top
// of the frame, clearing toward the bottom. Bands are crisp rather than the
// soft sinusoid real banding is but authentic banding is low-contrast luma and
// vanishes below 128px.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

typealias RGB = (CGFloat, CGFloat, CGFloat)
func hex(_ h: UInt32) -> RGB {
    (CGFloat((h >> 16) & 0xff)/255, CGFloat((h >> 8) & 0xff)/255, CGFloat(h & 0xff)/255)
}
func cg(_ c: RGB, _ a: CGFloat = 1) -> CGColor { CGColor(red: c.0, green: c.1, blue: c.2, alpha: a) }

let plateTop = hex(0xffffff), plateBottom = hex(0xe6ecf5)
let screenTop = hex(0x1d4795), screenBottom = hex(0x7cabf7)
let figureFill = hex(0x17408a)
let camBody = hex(0x123a80), camLens = hex(0x9cc2f9)

/// Apple's plate is a continuous-corner rounded rect, which CGPath does not
/// draw. On a square, a superellipse at n=6.5 is the usual approximation.
func squircle(center: CGPoint, half a: CGFloat, n: CGFloat = 6.5) -> CGPath {
    let path = CGMutablePath(), steps = 2048
    for i in 0...steps {
        let t = CGFloat(i)/CGFloat(steps) * 2 * .pi, c = cos(t), s = sin(t)
        let p = CGPoint(x: center.x + a*pow(abs(c), 2/n)*(c < 0 ? -1 : 1),
                        y: center.y + a*pow(abs(s), 2/n)*(s < 0 ? -1 : 1))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func icon(_ size: CGFloat) -> CGImage {
    let scale = size/1024, space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: size)          // authored top-down at 1024
    ctx.scaleBy(x: scale, y: -scale)

    func gradient(_ path: CGPath, _ from: RGB, _ to: RGB, _ y0: CGFloat, _ y1: CGFloat) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [cg(from), cg(to)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
        ctx.restoreGState()
    }

    gradient(squircle(center: CGPoint(x: 512, y: 512), half: 412), plateTop, plateBottom, 100, 924)

    // Dark at the top so the bands have contrast, pale at the bottom so the
    // silhouette does.
    let w: CGFloat = 684, h: CGFloat = 513
    let screen = CGRect(x: 512 - w/2, y: 512 - h/2 + 24, width: w, height: h)
    gradient(rounded(screen, 46), screenTop, screenBottom, screen.minY, screen.maxY)

    ctx.saveGState(); ctx.addPath(rounded(screen, 46)); ctx.clip()
    let headR = h/6, headY = screen.minY + h*0.36, shoulderW = w*0.594
    ctx.setFillColor(cg(figureFill))
    ctx.addEllipse(in: CGRect(x: 512 - headR, y: headY - headR, width: headR*2, height: headR*2))
    ctx.fillPath()
    // Runs past the bottom edge, so only the shoulder curve is ever drawn.
    ctx.addPath(rounded(CGRect(x: 512 - shoulderW/2, y: headY + headR*1.25,
                               width: shoulderW, height: h), shoulderW*0.42))
    ctx.fillPath()
    // Over the figure as well as the background: banding is exposure, so it
    // crosses everything in frame. Decaying, because bands that cross a figure
    // at constant contrast read as prison bars.
    for (i, falloff) in [1.0, 0.62, 0.28].enumerated() {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92 * CGFloat(falloff)))
        ctx.fill(CGRect(x: screen.minX, y: screen.minY + h*0.096 + CGFloat(i)*h*0.2,
                        width: w, height: h*0.1125))
    }
    ctx.restoreGState()

    // Straddles the top edge as if mounted on the monitor.
    let camW: CGFloat = 232, camH: CGFloat = 56, camY = screen.minY - 2
    ctx.setFillColor(cg(camBody))
    ctx.addPath(rounded(CGRect(x: 512 - camW/2, y: camY - camH/2, width: camW, height: camH),
                        camH*0.42))
    ctx.fillPath()
    ctx.setFillColor(cg(camLens))
    ctx.addEllipse(in: CGRect(x: 512 - 17, y: camY - 17, width: 34, height: 34))
    ctx.fillPath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(path)") }
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <Assets.xcassets>\n".data(using: .utf8)!)
    exit(2)
}
let set = CommandLine.arguments[1] + "/AppIcon.appiconset"
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)

// macOS wants each slot as its own file even where two share a pixel size.
let slots: [(idiom: String, size: Int, scale: Int)] = [
    ("16x16", 16, 1), ("16x16", 16, 2), ("32x32", 32, 1), ("32x32", 32, 2),
    ("128x128", 128, 1), ("128x128", 128, 2), ("256x256", 256, 1), ("256x256", 256, 2),
    ("512x512", 512, 1), ("512x512", 512, 2),
]
var entries: [String] = []
var rendered: [Int: CGImage] = [:]
for slot in slots {
    let px = slot.size * slot.scale
    let image = rendered[px] ?? icon(CGFloat(px))
    rendered[px] = image
    let name = "icon_\(slot.idiom)\(slot.scale == 2 ? "@2x" : "").png"
    write(image, to: "\(set)/\(name)")
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.idiom)"
        }
    """)
}
let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try! contents.write(toFile: "\(set)/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(slots.count) images to \(set)")
