// Draws the FrostFold app icon and writes an .iconset plus a PNG for the
// README. Everything is drawn in a 1024-unit space and scaled per size, so the
// small sizes stay legible rather than being downsampled mush.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// The macOS icon grid: the shape sits inside the canvas rather than filling it.
let canvas: CGFloat = 1024
let inset: CGFloat = 100
let side = canvas - inset * 2
let corner: CGFloat = 185

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

func draw(into ctx: CGContext, size: CGFloat) {
    let space = CGColorSpaceCreateDeviceRGB()
    ctx.scaleBy(x: size / canvas, y: size / canvas)

    let body = CGRect(x: inset, y: inset, width: side, height: side)
    let shape = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // The display with nothing left to show: the picture has folded away.
    ctx.setFillColor(rgb(8, 9, 18))
    ctx.fill(body)
    if let glow = CGGradient(colorsSpace: space,
                             colors: [rgb(38, 42, 86, 0.9), rgb(8, 9, 18, 0)] as CFArray,
                             locations: [0, 1]) {
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: canvas/2, y: inset + side * 0.18), startRadius: 0,
                               endCenter: CGPoint(x: canvas/2, y: inset + side * 0.18), endRadius: side * 0.62,
                               options: [])
    }

    // The pane: hinged along the bottom, folded away, so it converges upward.
    let hingeY = inset + side * 0.085
    let topY   = inset + side * 0.60
    let hingeHalf = side * 0.455
    let topHalf   = side * 0.285
    let cx = canvas / 2

    let pane = CGMutablePath()
    pane.move(to: CGPoint(x: cx - hingeHalf, y: hingeY))
    pane.addLine(to: CGPoint(x: cx + hingeHalf, y: hingeY))
    pane.addLine(to: CGPoint(x: cx + topHalf, y: topY))
    pane.addLine(to: CGPoint(x: cx - topHalf, y: topY))
    pane.closeSubpath()

    ctx.saveGState()
    ctx.addPath(pane)
    ctx.clip()

    // What the glass still carries, clear at the hinge.
    if let wallpaper = CGGradient(colorsSpace: space, colors: [
        rgb(58, 92, 214), rgb(126, 74, 200), rgb(228, 118, 96)] as CFArray,
        locations: [0, 0.5, 1]) {
        ctx.drawLinearGradient(wallpaper,
                               start: CGPoint(x: cx - hingeHalf, y: hingeY),
                               end: CGPoint(x: cx + hingeHalf, y: topY), options: [])
    }
    // Frost climbing with the gap: clear where it touches, milky where it lifts.
    if let frost = CGGradient(colorsSpace: space, colors: [
        rgb(255, 255, 255, 0.0), rgb(236, 242, 255, 0.55), rgb(244, 248, 255, 0.94)] as CFArray,
        locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(frost,
                               start: CGPoint(x: cx, y: hingeY),
                               end: CGPoint(x: cx, y: topY), options: [])
    }
    ctx.restoreGState()

    // The hinge itself, catching a little light.
    ctx.setStrokeColor(rgb(226, 236, 255, 0.85))
    ctx.setLineWidth(side * 0.012)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: cx - hingeHalf, y: hingeY))
    ctx.addLine(to: CGPoint(x: cx + hingeHalf, y: hingeY))
    ctx.strokePath()

    ctx.restoreGState()

    // A hairline so the shape holds its edge on a light background.
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(into: ctx, size: CGFloat(size))
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let iconset = "\(outDir)/FrostFold.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// The set iconutil expects.
let entries: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (size, name) in entries {
    write(render(size: size), to: "\(iconset)/\(name).png")
}
print("wrote \(iconset) (\(entries.count) sizes)")

// And a standalone PNG for the README, from the same drawing.
write(render(size: 512), to: "\(outDir)/icon.png")
print("wrote \(outDir)/icon.png")
