// Renders an SVG to a PNG of an exact pixel size, through WebKit.
//   rasterise in.svg out.png 1280 640
//
// WebKit because the banner's DM Sans travels inside the SVG as a woff2 data
// URL, and WebKit is the renderer on every Mac that honours that. Nothing here
// touches the screen: the view sits in a window that is never ordered in.

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 5, let width = Int(args[3]), let height = Int(args[4]) else {
    FileHandle.standardError.write("usage: rasterise in.svg out.png WIDTH HEIGHT\n".data(using: .utf8)!)
    exit(64)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("rasterise: \(message)\n".data(using: .utf8)!)
    exit(1)
}

final class Renderer: NSObject, WKNavigationDelegate {
    let input: URL, output: URL
    let width: Int, height: Int
    let view: WKWebView
    let window: NSWindow

    init(input: URL, output: URL, width: Int, height: Int) {
        self.input = input
        self.output = output
        self.width = width
        self.height = height
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        view = WKWebView(frame: frame)
        // A snapshot needs the view in a window; this one is never shown.
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.contentView = view
        view.navigationDelegate = self
    }

    func start() {
        view.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // `didFinish` can arrive before the embedded faces are decoded, and a
        // snapshot taken then is set in the fallback font.
        webView.callAsyncJavaScript("await document.fonts.ready; return document.fonts.size",
                                    arguments: [:], in: nil, in: .page) { result in
            if case .failure(let error) = result { fail("fonts: \(error.localizedDescription)") }
            self.snap()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error.localizedDescription)
    }

    func snap() {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: width, height: height)
        view.takeSnapshot(with: config) { image, error in
            guard let image else { fail("snapshot: \(error?.localizedDescription ?? "no image")") }
            // The snapshot comes back at the backing scale, so draw it into a
            // bitmap of the size asked for rather than trusting its pixels.
            let (width, height) = (self.width, self.height)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                fail("could not make a bitmap")
            }
            rep.size = NSSize(width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { fail("could not encode PNG") }
            do { try png.write(to: self.output) } catch { fail(error.localizedDescription) }
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(input: input, output: output, width: width, height: height)
renderer.start()
app.run()
