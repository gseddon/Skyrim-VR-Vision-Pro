// What the app draws over the game's picture in each eye's drawable: the performance panel (VXStatsPanel.swift), as a quad fixed to
// the head.
//
// A quad, not a copy of pixels: the panel is translucent with round corners, which a pass can blend over the game and a copy cannot.
// And a foveated drawable's texture is not a plain picture. It is rasterized through a rate map (dense where the eye looks, sparse at
// the edge) and the system unwarps it on the way to the display, so pixels copied into it land warped and move with the gaze. A pass
// that sets the map draws in the display's own coordinates. The same pass works without a map, which is the case today: this app's
// layer is configured without foveation (VXLayerConfiguration).
import CompositorServices
import Metal
import simd

enum VXDisplay {
    /// An eye's rate map and viewport for a pass into its texture; no map on a drawable that is not foveated, or whose maps are not
    /// one a view (a pass that selects one texture can only reach its own map).
    static func raster(_ d: LayerRenderer.Drawable, view i: Int) -> (map: MTLRasterizationRateMap?, viewport: MTLViewport) {
        let maps = d.rasterizationRateMaps
        let viewport = d.views[i].textureMap.viewport
        return (maps.count == d.views.count ? maps[i] : nil, viewport)
    }
}

final class VXOverlayQuad {
    private var pipeline: MTLRenderPipelineState?
    private var format: MTLPixelFormat = .invalid
    private var sampler: MTLSamplerState?
    private var failed = false

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct P { float4 rect; };
    struct V { float4 position [[position]]; float2 uv; };
    vertex V ov(uint i [[vertex_id]], constant P &p [[buffer(0)]]) {
        float2 c = float2((i & 1) ? 1.0 : -1.0, (i & 2) ? 1.0 : -1.0);
        V v;
        v.position = float4(p.rect.xy + c * p.rect.zw, 0.05, 1.0);
        v.uv = float2((c.x + 1.0) * 0.5, (1.0 - c.y) * 0.5);
        return v;
    }
    fragment float4 of(V v [[stage_in]], texture2d<float> img [[texture(0)]], sampler smp [[sampler(0)]]) {
        return img.sample(smp, v.uv);
    }
    """

    private func prepare(_ device: MTLDevice, _ color: MTLPixelFormat) -> Bool {
        if pipeline != nil && format == color { return true }
        if failed { return false }
        do {
            let lib = try device.makeLibrary(source: Self.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "ov"); d.fragmentFunction = lib.makeFunction(name: "of")
            d.colorAttachments[0].pixelFormat = color
            // the picture's alpha is premultiplied (CoreGraphics): a translucent panel with round corners over the game
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one; d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one; d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: d)
            let s = MTLSamplerDescriptor()
            s.minFilter = .linear; s.magFilter = .linear; s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: s)
            format = color
        } catch {
            failed = true
            vxrt_jlog("overlay_error", "\"what\":\"\(String(describing: error).prefix(200).replacingOccurrences(of: "\"", with: "'"))\"")
        }
        return pipeline != nil && sampler != nil
    }

    /// Draws `texture` over `color` as a quad with its middle at `centre` and half extents `half`, both in normalized device
    /// coordinates of the eye. `map` and `viewport` are the eye's (VXDisplay.raster).
    @discardableResult
    func draw(cb: MTLCommandBuffer, color: MTLTexture, texture: MTLTexture, centre: SIMD2<Float>, half: SIMD2<Float>,
              map: MTLRasterizationRateMap?, viewport: MTLViewport) -> Bool {
        guard prepare(cb.device, color.pixelFormat), let pipeline, let sampler else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        if let map { pass.rasterizationRateMap = map }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if map != nil, viewport.width > 0, viewport.height > 0 { enc.setViewport(viewport) }
        var rect = SIMD4<Float>(centre.x, centre.y, half.x, half.y)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return true
    }

    /// Where a card `size` metres wide and high lies in this eye, `distance` metres ahead of the head with its middle `offset` metres
    /// to the right of and above straight ahead: its middle and half extents in normalized device coordinates, and how many pixels
    /// wide it is on the display. `view` is the drawable's eye transform (head from eye), `projection` its projection (right-up-back).
    static func place(size: SIMD2<Float>, distance: Float, offset: SIMD2<Float>, view: simd_float4x4, projection: simd_float4x4,
                      displayWidth: Double) -> (centre: SIMD2<Float>, half: SIMD2<Float>, pixels: Int)? {
        let p = projection * (view.inverse * SIMD4<Float>(offset.x, offset.y, -distance, 1))
        guard p.w > 0, distance > 0 else { return nil }
        let half = SIMD2<Float>(size.x * 0.5 * projection.columns.0.x / distance, size.y * 0.5 * projection.columns.1.y / distance)
        return (SIMD2<Float>(p.x / p.w, p.y / p.w), half, Int(Double(half.x) * displayWidth))
    }

    /// A texture for a CoreGraphics bitmap (BGRA, premultiplied alpha, sRGB bytes).
    static func makeTexture(_ device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        return device.makeTexture(descriptor: d)
    }
}
