// Renders the glass pane over a still image at a series of lid angles.
//
// It exists so the effect can be inspected, tuned and screenshotted without
// opening and closing the lid, and so the README images can be regenerated
// from a command. Build it with Scripts/filmstrip.sh.

import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import simd

// MARK: - Arguments

func argument(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

if CommandLine.arguments.contains("--help") {
    print("""
    filmstrip — render the FrostFold pane over a still image

      --input  <file.png>   background image (default: a synthetic desktop)
      --out    <dir>        output directory (default: ./filmstrip)
      --mode   lift|seethrough|both   (default: both)
      --angles 125,100,75,50,25,8     lid angles in degrees
      --clean               drop the alignment grid from the synthetic desktop
    """)
    exit(0)
}

let outDir = argument("--out") ?? "filmstrip"
let modeArg = argument("--mode") ?? "both"
let angles = (argument("--angles") ?? "125,100,75,50,25,8")
    .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: - Background

let clean = CommandLine.arguments.contains("--clean")

func syntheticDesktop(width: Int, height: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)!
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.10, green: 0.16, blue: 0.38, alpha: 1),
        CGColor(red: 0.42, green: 0.18, blue: 0.45, alpha: 1),
        CGColor(red: 0.92, green: 0.45, blue: 0.32, alpha: 1)] as CFArray,
        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: width, y: height), options: [])

    ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.85))
    ctx.fill(CGRect(x: 0, y: height - 34, width: width, height: 34))

    func window(_ r: CGRect, _ tint: CGColor) {
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 0.97)); ctx.fill(r)
        ctx.setFillColor(tint)
        ctx.fill(CGRect(x: r.minX, y: r.maxY - 30, width: r.width, height: 30))
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        for i in 0..<Int((r.height - 50) / 22) {
            let w = r.width * (i % 3 == 0 ? 0.75 : 0.5)
            ctx.fill(CGRect(x: r.minX + 16, y: r.maxY - 56 - CGFloat(i) * 22, width: w - 32, height: 9))
        }
    }
    window(CGRect(x: 90, y: 180, width: 620, height: 600),
           CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    window(CGRect(x: 780, y: 90, width: 700, height: 520),
           CGColor(red: 0.9, green: 0.3, blue: 0.4, alpha: 1))

    // A fine grid makes any perspective error obvious at a glance — useful when
    // tuning the shader, noise when producing a presentable still.
    guard !clean else { return ctx.makeImage()! }
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28)); ctx.setLineWidth(1)
    for x in stride(from: 0, through: width, by: 50) {
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: height))
    }
    for y in stride(from: 0, through: height, by: 50) {
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: width, y: y))
    }
    ctx.strokePath()
    return ctx.makeImage()!
}

let background: CGImage = {
    guard let path = argument("--input") else { return syntheticDesktop(width: 1600, height: 1000) }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("error: could not read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return img
}()

let W = background.width, H = background.height

// MARK: - Metal

func texture(from image: CGImage, device: MTLDevice) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                     width: image.width, height: image.height,
                                                     mipmapped: false)
    d.usage = [.shaderRead]; d.storageMode = .shared
    let tex = device.makeTexture(descriptor: d)!
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(data: &bytes, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    tex.replace(region: MTLRegionMake2D(0, 0, image.width, image.height),
                mipmapLevel: 0, withBytes: bytes, bytesPerRow: image.width * 4)
    return tex
}

func writePNG(_ tex: MTLTexture, to path: String) {
    var bytes = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
    tex.getBytes(&bytes, bytesPerRow: tex.width * 4,
                 from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
    let ctx = CGContext(data: &bytes, width: tex.width, height: tex.height,
                        bitsPerComponent: 8, bytesPerRow: tex.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

guard let renderer = MetalRenderer() else {
    FileHandle.standardError.write("error: could not create the Metal renderer\n".data(using: .utf8)!)
    exit(1)
}
let device = renderer.device
let source = texture(from: background, device: device)

let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                        width: W, height: H, mipmapped: false)
outDesc.usage = [.renderTarget, .shaderRead]
outDesc.storageMode = .shared

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
}

let settings = Settings.shared
print("background \(W)×\(H)  →  \(outDir)/")

for angle in angles {
    // The same arithmetic the app runs, not a copy of it.
    let u = FoldGeometry.uniforms(.init(
        lidAngle: angle,
        engageAngle: settings.restAngle,
        shutAngle: settings.shutAngle,
        hingeSensitivity: settings.hingeSensitivity,
        maxFold: settings.maxFold,
        perspective: settings.perspective,
        edgeSoftness: settings.edgeSoftness,
        cornerRadiusPoints: settings.cornerRadius,
        dimming: settings.dimming,
        frostGain: settings.intensity.frostGain,
        aspect: Float(W) / Float(H),
        // The synthetic desktop stands in for a display of this height.
        displayHeightPoints: Double(H),
        drawableSize: SIMD2(Float(W), Float(H))))

    let target = device.makeTexture(descriptor: outDesc)!
    renderer.render(to: target, source: source, uniforms: u, opaqueBackground: true)

    let file = String(format: "%@/fold-%03.0f.png", outDir, angle)
    writePNG(target, to: file)

    let tilt = Double(u.foldRadians)
    print(String(format: "  lid %5.1f°  fold %.3f  tilt %4.1f°  frost@edge %.2f  fill %.2f",
                 angle, settings.fold(forLidAngle: angle), tilt * 180 / .pi,
                 min(1.0, Double(u.frostAmount) * sin(tilt)), Double(u.blackout)))
}
