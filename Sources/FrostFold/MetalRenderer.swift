import Metal
import QuartzCore
import simd

/// Builds the frosted pane: reduce the captured frame into a blur pyramid, then
/// draw it over the display with a frost gradient driven by the pane's gap.
final class MetalRenderer {

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let downsamplePipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private let blackoutPipeline: MTLRenderPipelineState
    private let panePipeline: MTLRenderPipelineState

    /// Progressively smaller, progressively softer copies of the captured
    /// frame. The fragment shader walks these by the local frost amount, which
    /// defocuses rather than merely hazing.
    private struct Pyramid {
        var half: MTLTexture
        var quarter: MTLTexture
        var quarterTmp: MTLTexture
        var eighth: MTLTexture
        var eighthTmp: MTLTexture
        var sixteenth: MTLTexture
        var sixteenthTmp: MTLTexture
    }
    private var pyramid: Pyramid?
    private var pyramidSize: (Int, Int) = (0, 0)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            NSLog("FrostFold: shader compilation failed — \(error)")
            return nil
        }

        func pipeline(_ vertex: String, _ fragment: String, blending: Bool) -> MTLRenderPipelineState? {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = desc.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            if blending {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: desc)
        }

        guard let ds = pipeline("blit_vertex", "downsample_fragment", blending: false),
              let bl = pipeline("blit_vertex", "blur_fragment", blending: false),
              let cp = pipeline("blit_vertex", "copy_fragment", blending: false),
              let bo = pipeline("blit_vertex", "blackout_fragment", blending: true),
              let pn = pipeline("pane_vertex", "pane_fragment", blending: true) else { return nil }

        downsamplePipeline = ds
        blurPipeline = bl
        copyPipeline = cp
        blackoutPipeline = bo
        panePipeline = pn
    }

    // MARK: - Scratch allocation

    private func makeTexture(_ width: Int, _ height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(1, width), height: max(1, height), mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    private func ensurePyramid(for source: MTLTexture) {
        let key = (source.width, source.height)
        guard key != pyramidSize || pyramid == nil else { return }
        pyramidSize = key
        let (w, h) = key
        guard let half = makeTexture(w / 2, h / 2),
              let quarter = makeTexture(w / 4, h / 4),
              let quarterTmp = makeTexture(w / 4, h / 4),
              let eighth = makeTexture(w / 8, h / 8),
              let eighthTmp = makeTexture(w / 8, h / 8),
              let sixteenth = makeTexture(w / 16, h / 16),
              let sixteenthTmp = makeTexture(w / 16, h / 16) else { pyramid = nil; return }
        pyramid = Pyramid(half: half, quarter: quarter, quarterTmp: quarterTmp,
                          eighth: eighth, eighthTmp: eighthTmp,
                          sixteenth: sixteenth, sixteenthTmp: sixteenthTmp)
    }

    private func fullscreenPass(_ buffer: MTLCommandBuffer,
                                pipeline: MTLRenderPipelineState,
                                source: MTLTexture,
                                target: MTLTexture,
                                blur: Shaders.BlurUniforms? = nil) {
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = .dontCare
        desc.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: desc) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        if var blur {
            encoder.setFragmentBytes(&blur, length: MemoryLayout<Shaders.BlurUniforms>.stride, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// One horizontal plus one vertical pass, via the scratch texture.
    private func blur(_ buffer: MTLCommandBuffer, _ texture: MTLTexture, _ scratch: MTLTexture,
                      passes: Int = 1) {
        for _ in 0..<passes {
            fullscreenPass(buffer, pipeline: blurPipeline, source: texture, target: scratch,
                           blur: .init(direction: SIMD2(1, 0)))
            fullscreenPass(buffer, pipeline: blurPipeline, source: scratch, target: texture,
                           blur: .init(direction: SIMD2(0, 1)))
        }
    }

    // MARK: - Frame

    /// `opaqueBackground` paints the captured display behind the pane; the
    /// preview window needs it, the live overlay does not (the real desktop is
    /// already there).
    func render(to layer: CAMetalLayer,
                source: MTLTexture?,
                uniforms: Shaders.PaneUniforms,
                opaqueBackground: Bool = false) {
        guard let drawable = layer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }
        encode(into: buffer, target: drawable.texture, source: source,
               uniforms: uniforms, opaqueBackground: opaqueBackground)
        buffer.present(drawable)
        buffer.commit()
    }

    /// Offscreen variant, used by the filmstrip tool and by tests. Blocks until
    /// the GPU has finished.
    func render(to target: MTLTexture,
                source: MTLTexture?,
                uniforms: Shaders.PaneUniforms,
                opaqueBackground: Bool = false) {
        guard let buffer = queue.makeCommandBuffer() else { return }
        encode(into: buffer, target: target, source: source,
               uniforms: uniforms, opaqueBackground: opaqueBackground)
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    private func encode(into buffer: MTLCommandBuffer,
                        target: MTLTexture,
                        source: MTLTexture?,
                        uniforms: Shaders.PaneUniforms,
                        opaqueBackground: Bool) {
        var uniforms = uniforms

        let visible = uniforms.opacity > 0.001 && uniforms.foldRadians > 0.0001

        guard let source, visible || opaqueBackground else {
            // Nothing to show — clear to transparent so the desktop shows through.
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture = target
            desc.colorAttachments[0].loadAction = .clear
            desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            desc.colorAttachments[0].storeAction = .store
            buffer.makeRenderCommandEncoder(descriptor: desc)?.endEncoding()
            return
        }

        if opaqueBackground {
            fullscreenPass(buffer, pipeline: copyPipeline, source: source, target: target)
        }

        ensurePyramid(for: source)

        // Build the pyramid: each level is smaller and softer than the last.
        var l1 = source, l2 = source, l3 = source
        if let p = pyramid, visible {
            fullscreenPass(buffer, pipeline: downsamplePipeline, source: source, target: p.half)
            fullscreenPass(buffer, pipeline: downsamplePipeline, source: p.half, target: p.quarter)
            blur(buffer, p.quarter, p.quarterTmp)

            fullscreenPass(buffer, pipeline: downsamplePipeline, source: p.quarter, target: p.eighth)
            blur(buffer, p.eighth, p.eighthTmp, passes: 2)

            fullscreenPass(buffer, pipeline: downsamplePipeline, source: p.eighth, target: p.sixteenth)
            blur(buffer, p.sixteenth, p.sixteenthTmp, passes: 3)

            l1 = p.quarter; l2 = p.eighth; l3 = p.sixteenth
        }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = opaqueBackground ? .load : .clear
        desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        desc.colorAttachments[0].storeAction = .store

        guard visible, let encoder = buffer.makeRenderCommandEncoder(descriptor: desc) else {
            if !opaqueBackground {
                buffer.makeRenderCommandEncoder(descriptor: desc)?.endEncoding()
            }
            return
        }

        // The picture has lifted away with the glass, so whatever the pane no
        // longer covers has nothing left to show.
        encoder.setRenderPipelineState(blackoutPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Shaders.PaneUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(panePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Shaders.PaneUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Shaders.PaneUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(l1, index: 1)
        encoder.setFragmentTexture(l2, index: 2)
        encoder.setFragmentTexture(l3, index: 3)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}
