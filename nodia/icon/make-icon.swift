import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Generates nodia's app icon: a macOS squircle with a gradient + a white
// magnifier glyph. `preview` renders 1024px variants; `iconset <name>` renders
// a full .iconset for one variant.

let cs = CGColorSpaceCreateDeviceRGB()

func col(_ hex: UInt, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

struct Variant { let top: UInt; let bottom: UInt }
let variants: [String: Variant] = [
    "indigo": Variant(top: 0x7C66FF, bottom: 0x4B2EC9),
    "teal":   Variant(top: 0x37D9D2, bottom: 0x0E7CB8),
    "sunset": Variant(top: 0xFF9A5A, bottom: 0xE8447B),
]
let order = ["indigo", "teal", "sunset"]

/// Draws a bold open "A" with a small "+" (Arc, enhanced), centered in an
/// `S`×`S` context. Shared geometry so the menu-bar template matches.
func drawAPlus(_ ctx: CGContext, _ S: CGFloat, color: CGColor, shadow: CGColor?) {
    ctx.saveGState()
    if let shadow { ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.008), blur: S * 0.02, color: shadow) }
    ctx.setStrokeColor(color)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)

    // the A: two legs meeting at an apex
    ctx.setLineWidth(S * 0.090)
    let apex = CGPoint(x: S * 0.435, y: S * 0.715)
    let bl = CGPoint(x: S * 0.265, y: S * 0.300)
    let br = CGPoint(x: S * 0.605, y: S * 0.300)
    ctx.move(to: bl); ctx.addLine(to: apex); ctx.addLine(to: br); ctx.strokePath()

    // crossbar
    let t: CGFloat = 0.40
    ctx.move(to: CGPoint(x: bl.x + (apex.x - bl.x) * t, y: bl.y + (apex.y - bl.y) * t))
    ctx.addLine(to: CGPoint(x: br.x + (apex.x - br.x) * t, y: br.y + (apex.y - br.y) * t))
    ctx.strokePath()

    // the +, upper-right
    let pc = CGPoint(x: S * 0.700, y: S * 0.655)
    let pa = S * 0.060
    ctx.setLineWidth(S * 0.072)
    ctx.move(to: CGPoint(x: pc.x - pa, y: pc.y)); ctx.addLine(to: CGPoint(x: pc.x + pa, y: pc.y)); ctx.strokePath()
    ctx.move(to: CGPoint(x: pc.x, y: pc.y - pa)); ctx.addLine(to: CGPoint(x: pc.x, y: pc.y + pa)); ctx.strokePath()

    ctx.restoreGState()
}

func render(_ v: Variant, _ size: Int) -> CGImage {
    let S = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

    let margin = S * 0.10
    let art = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let path = CGPath(roundedRect: art, cornerWidth: art.width * 0.2237,
                      cornerHeight: art.width * 0.2237, transform: nil)

    // soft drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: col(0, 0.28))
    ctx.addPath(path); ctx.setFillColor(col(v.bottom)); ctx.fillPath()
    ctx.restoreGState()

    // gradient fill + top highlight
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [col(v.top), col(v.bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: art.midX, y: art.maxY),
                           end: CGPoint(x: art.midX, y: art.minY), options: [])
    let hl = CGGradient(colorsSpace: cs, colors: [col(0xFFFFFF, 0.20), col(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: art.midX, y: art.maxY),
                           end: CGPoint(x: art.midX, y: art.midY), options: [])
    ctx.restoreGState()

    // crisp inner hairline
    ctx.saveGState()
    ctx.addPath(path); ctx.setStrokeColor(col(0xFFFFFF, 0.12)); ctx.setLineWidth(max(1, S * 0.005)); ctx.strokePath()
    ctx.restoreGState()

    // "A+" glyph: a bold open A with a small plus (Arc, enhanced)
    drawAPlus(ctx, S, color: col(0xFFFFFF), shadow: col(0, 0.22))

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "preview"
let fm = FileManager.default

if mode == "preview" {
    let out = URL(fileURLWithPath: "icon/preview")
    try? fm.createDirectory(at: out, withIntermediateDirectories: true)
    for key in order {
        writePNG(render(variants[key]!, 1024), out.appendingPathComponent("nodia-\(key).png"))
        print("wrote icon/preview/nodia-\(key).png")
    }
} else if mode == "iconset", args.count > 2, let v = variants[args[2]] {
    let out = URL(fileURLWithPath: "icon/AppIcon.iconset")
    try? fm.createDirectory(at: out, withIntermediateDirectories: true)
    let specs: [(Int, String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for (sz, name) in specs { writePNG(render(v, sz), out.appendingPathComponent(name)) }
    print("wrote icon/AppIcon.iconset for \(args[2])")
} else {
    print("usage: make-icon.swift [preview | iconset <indigo|teal|sunset>]")
}
