import Metal
import QuartzCore
import simd

/// Builds the frosted pane: reduce the captured frame, diffuse it, then draw it
/// onto a hinged quad with the etched-glass fragment shader.
final class MetalRenderer {

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let downsamplePipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private let panePipeline: MTLRenderPipelineState

    // Ping-pong scratch for the reduce/blur chain.
    private var half: MTLTexture?
    private var quarter: MTLTexture?
    private var scratch: MTLTexture?
    private var chainSize: (Int, Int) = (0, 0)

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
              let pn = pipeline("pane_vertex", "pane_fragment", blending: true) else { return nil }

        downsamplePipeline = ds
        blurPipeline = bl
        copyPipeline = cp
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

    private func ensureChain(for source: MTLTexture) {
        let key = (source.width, source.height)
        guard key != chainSize else { return }
        chainSize = key
        half = makeTexture(key.0 / 2, key.1 / 2)
        quarter = makeTexture(key.0 / 4, key.1 / 4)
        scratch = makeTexture(key.0 / 4, key.1 / 4)
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

    // MARK: - Frame

    /// Draws one frame. Pass `source == nil` to clear the layer to fully
    /// transparent (used when the effect is idle).
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

        guard let source, uniforms.opacity > 0.001 || opaqueBackground else {
            // Nothing to show — clear to transparent so the desktop shows through.
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture = target
            desc.colorAttachments[0].loadAction = .clear
            desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            desc.colorAttachments[0].storeAction = .store
            buffer.makeRenderCommandEncoder(descriptor: desc)?.endEncoding()
            return
        }

        ensureChain(for: source)

        if opaqueBackground {
            fullscreenPass(buffer, pipeline: copyPipeline, source: source, target: target)
        }

        var diffused = source
        if let half, let quarter, let scratch {
            fullscreenPass(buffer, pipeline: downsamplePipeline, source: source, target: half)
            fullscreenPass(buffer, pipeline: downsamplePipeline, source: half, target: quarter)

            // Heavier frost earns extra separable passes rather than a wider,
            // more expensive kernel.
            let iterations = 1 + Int((uniforms.scatter * 2).rounded())
            for _ in 0..<iterations {
                fullscreenPass(buffer, pipeline: blurPipeline, source: quarter, target: scratch,
                               blur: .init(direction: SIMD2(1, 0)))
                fullscreenPass(buffer, pipeline: blurPipeline, source: scratch, target: quarter,
                               blur: .init(direction: SIMD2(0, 1)))
            }
            diffused = quarter
        }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = target
        desc.colorAttachments[0].loadAction = opaqueBackground ? .load : .clear
        desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        desc.colorAttachments[0].storeAction = .store

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: desc) else { return }
        encoder.setRenderPipelineState(panePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Shaders.PaneUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Shaders.PaneUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(diffused, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}