// The loading screen, shown in the immersive space until the first game pair has been presented (never again after that):
// a dark background, "Loading Skyrim VR..." and a progress bar, head-locked at about 2 m. The picture is a small bitmap drawn once
// per progress step with CoreGraphics/CoreText into a texture and drawn over each eye's drawable as a quad (VXOverlay.swift: no
// per-frame CPU drawing; a copy of pixels would land warped in a foveated drawable). The bar is the runtime's own milestones (vx_xros_load_stage: host up, game session begun, first pair
// submitted, first pair shown), eased so it never jumps or goes backwards.
import CoreGraphics
import CoreText
import Metal
import QuartzCore
import simd

final class VXLoadingCard {
    // The background is part of the card's bitmap and must equal the pass's clear colour: sRGB byte 16 is linear 0.00518.
    static let backgroundByte: UInt8 = 16
    static let clearLinear = 0.00518
    // The card is 1.4 m wide and 0.37 m high at 2 m (device run B: 0.9 m came out small, about a sixth of the eye image).
    static let widthMeters: Float = 1.4, heightMeters: Float = 0.37, distanceMeters: Float = 2.0

    private var texture: MTLTexture?
    private let quad = VXOverlayQuad()
    private var cardWidth = 0, cardHeight = 0
    private var drawnStep = -1
    private var progress = 0.0, lastTick = CACurrentMediaTime(), stage = 0
    private let start = CACurrentMediaTime()
    private var stageSince = CACurrentMediaTime()
    // the bar's value when a stage is reached, and what it creeps towards while the stage lasts
    private static let floors: [Double] = [0.04, 0.22, 0.45, 0.80, 1.0]
    private static let ceilings: [Double] = [0.20, 0.42, 0.78, 0.97, 1.0]
    private static let labels = ["Starting", "Preparing the game", "Loading the game", "Almost ready", "Ready"]

    // Advance the bar. `shown` is true once the first game pair has been presented.
    private func tick(shown: Bool) {
        let now = CACurrentMediaTime(), dt = min(0.25, now - lastTick)
        lastTick = now
        var s = 0
#if XRIZER_XROS_FIXTURE
        s = Int(vx_xros_load_stage())
#endif
        if shown { s = 4 }
        if s != stage { stage = s; stageSince = now }
        // ease toward the stage's floor quickly, then creep toward its ceiling slowly (never reaching it) while the stage lasts
        let floor = Self.floors[min(stage, 4)], ceil = Self.ceilings[min(stage, 4)]
        let target = max(floor, min(ceil, floor + (ceil - floor) * (1 - exp(-(now - stageSince) / 25))))
        let rate = stage == 4 ? 3.0 : 1.2
        progress = min(1, max(progress, progress + (target - progress) * min(1, rate * dt)))
    }

    // Draw (if the bar moved by a visible step) the card over `color`, as a quad with its middle where a point 2 m straight ahead falls in
    // this eye (VXOverlay.swift; through the eye's rate map when the drawable is foveated). `view` is the drawable's eye transform (head
    // from eye); `projection` its projection (right-up-back). Returns false if it could not be drawn this frame.
    func encode(cb: MTLCommandBuffer, color: MTLTexture, eye: Int, view: simd_float4x4, projection: simd_float4x4, shown: Bool,
                map: MTLRasterizationRateMap?, viewport: MTLViewport) -> Bool {
        if eye == 0 { tick(shown: shown) }
        guard color.pixelFormat == .bgra8Unorm_srgb || color.pixelFormat == .bgra8Unorm else { return false }
        let displayWidth = map != nil && viewport.width > 0 ? viewport.width : Double(color.width)
        guard let at = VXOverlayQuad.place(size: SIMD2(Self.widthMeters, Self.heightMeters), distance: Self.distanceMeters, offset: SIMD2(0, 0),
                                           view: view, projection: projection, displayWidth: displayWidth) else { return false }
        // as many pixels as the card gets on the display (bounded: a foveated display is rasterized at up to 6000 pixels across)
        let w = min(at.pixels & ~1, 1600), h = Int(Float(w) * Self.heightMeters / Self.widthMeters) & ~1
        guard w >= 64, h >= 24 else { return false }
        let step = Int(progress * 400) + stage * 1000
        if texture == nil || w != cardWidth || h != cardHeight {
            cardWidth = w; cardHeight = h
            texture = VXOverlayQuad.makeTexture(cb.device, width: w, height: h)
            drawnStep = -1
        }
        guard let tex = texture else { return false }
        if step != drawnStep { render(into: tex, width: w, height: h); drawnStep = step }
        return quad.draw(cb: cb, color: color, texture: tex, centre: at.centre, half: at.half, map: map, viewport: viewport)
    }

    private func render(into tex: MTLTexture, width w: Int, height h: Int) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
              let data = ctx.data else { return }
        defer { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4) }
        let bg = CGFloat(Self.backgroundByte) / 255
        ctx.setFillColor(CGColor(red: bg, green: bg, blue: bg, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let fw = CGFloat(w), fh = CGFloat(h)
        // title (top third) and the stage label (small, under the bar)
        func line(_ text: String, size: CGFloat, gray: CGFloat, centerY: CGFloat) {
            let font = CTFontCreateWithName("HelveticaNeue-Light" as CFString, size, nil)
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: gray, green: gray, blue: gray, alpha: 1)]
            let ct = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary))
            let bounds = CTLineGetBoundsWithOptions(ct, [])
            ctx.textPosition = CGPoint(x: (fw - bounds.width) / 2 - bounds.minX, y: centerY - bounds.height / 2 - bounds.minY)
            CTLineDraw(ct, ctx)
        }
        line("Loading Skyrim VR\u{2026}", size: fh * 0.30, gray: 0.88, centerY: fh * 0.72)
        // bar: a rounded track and fill
        let barW = fw * 0.78, barH = fh * 0.075, barX = (fw - barW) / 2, barY = fh * 0.36
        let track = CGPath(roundedRect: CGRect(x: barX, y: barY, width: barW, height: barH), cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
        ctx.setFillColor(CGColor(red: 0.20, green: 0.20, blue: 0.21, alpha: 1))
        ctx.addPath(track); ctx.fillPath()
        let fillW = max(barH, barW * CGFloat(progress))
        let fill = CGPath(roundedRect: CGRect(x: barX, y: barY, width: fillW, height: barH), cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)
        ctx.setFillColor(CGColor(red: 0.90, green: 0.91, blue: 0.94, alpha: 1))
        ctx.addPath(fill); ctx.fillPath()
        line(Self.labels[min(stage, 4)], size: fh * 0.115, gray: 0.55, centerY: fh * 0.16)
    }
}
