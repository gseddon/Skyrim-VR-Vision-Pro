// The compositor loop of VX Runtime's immersive space (VISIONOS_PORT.md, "VR presentation"): every compositor frame
// (90 Hz on the headset), the head's pose at the frame's presentation time (ARKit world tracking), then each eye: the
// newest game frame warped to that eye by the runtime (src/xros_vr.m: the warp core with the game's depth: head
// rotation reprojection, the eyes' parallax, the NPU race's predictions from the game's motion vectors), depth into
// the drawable for the system's own late reprojection, the drawable's device anchor the pose the eyes were made for.
// The game renders at its own rate; its sync-interval presents are paced by these frames (vx_xros_vr_begin_frame).
import ARKit
import CompositorServices
import Metal
import QuartzCore
import simd
import Darwin

final class VXImmersiveRenderer: @unchecked Sendable {
    private let layerRenderer: LayerRenderer
    private let queue: MTLCommandQueue
    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let trackingGate = VXTrackingGate()
    private let nativeInput = VXNativeInput()
    private var tracking = false
    private var lastReport = CACurrentMediaTime()
    private var cleared = 0
    private var nativeXRTracking: VXNativeXRTracking?
    private var spatialClockCalibrated = false
    private var lastSpatialSample = 0.0
#if XRIZER_XROS_FIXTURE
    private var xrizerFixtureAttempted = false
    private var xrizerFixtureObserved = false
    private var xrizerFixtureOffscreenOffers = 0
    private var xrizerHeadFrames = 0
    private var xrizerHeadLogged = false
    private var xrizerFixtureSurface = VXFixtureSurfaceState()
    private var xrizerFixtureStarted = false
    private var immersiveLogged = false
#endif
    private static let near: Float = 0.1, far: Float = 10000

    static func start(_ layerRenderer: LayerRenderer) {
        guard let q = layerRenderer.device.makeCommandQueue() else {
            vxrt_jlog("vr_error", "\"what\":\"no command queue\"")
            return
        }
        let r = VXImmersiveRenderer(layerRenderer, q)
        Task {
            if WorldTrackingProvider.isSupported {
                var handsAllowed = false
                if HandTrackingProvider.isSupported && vx_xros_native_enabled() != 0 {
                    let authorization = await r.arSession.requestAuthorization(for: [.handTracking])
                    handsAllowed = authorization[.handTracking] == .allowed
                }
                do {
                    if handsAllowed {
                        do {
                            try await r.arSession.run([r.worldTracking, r.nativeInput.hands])
                            r.nativeInput.handTrackingEnabled = true
                        } catch {
                            vxrt_jlog("vr_error", "\"what\":\"hand tracking unavailable\"")
                            try await r.arSession.run([r.worldTracking])
                        }
                    } else { try await r.arSession.run([r.worldTracking]) }
                    r.tracking = true
                    if vx_xros_native_enabled() != 0 {
                        r.spatialClockCalibrated = Self.clockMatchesMach()
                        if r.spatialClockCalibrated {
                            let adapter = VXNativeXRTracking(session: r.arSession, world: r.worldTracking,
                                hands: r.nativeInput.handTrackingEnabled ? r.nativeInput.hands : nil, gate: r.trackingGate)
                            r.nativeXRTracking = adapter
                            await adapter.start()
                        } else {
                            vxrt_jlog("vr_error", "\"what\":\"spatial clock calibration failed\"")
                        }
                    }
                } catch { vxrt_jlog("vr_error", "\"what\":\"world tracking: \(error.localizedDescription)\"") }
            }
            let thread = Thread { r.loop() }
            thread.name = "VX compositor"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    private init(_ layerRenderer: LayerRenderer, _ queue: MTLCommandQueue) {
        self.layerRenderer = layerRenderer
        self.queue = queue
        queue.label = "VX compositor"
    }

#if XRIZER_XROS_FIXTURE
    // Controllers feed the provider every frame; the unattached diagnostic samples at 10 Hz.
    private static let spatialSampleInterval = 0.008
#else
    private static let spatialSampleInterval = 0.1
#endif

    private static func seconds(_ i: LayerRenderer.Clock.Instant) -> Double {
        let c = LayerRenderer.Clock.Instant.epoch.duration(to: i).components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }

    // CompositorServices and ARKit use Mach absolute time. Check the Swift
    // Instant epoch against bracketing Mach reads before passing its seconds
    // to accessory prediction; a failed comparison disables collection.
    private static func clockMatchesMach() -> Bool {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer != 0, info.denom != 0 else { return false }
        let before = mach_absolute_time()
        let compositor = seconds(LayerRenderer.Clock().now)
        let after = mach_absolute_time()
        let factor = Double(info.numer) / Double(info.denom) / 1e9
        let low = Double(before) * factor, high = Double(after) * factor
        return compositor.isFinite && compositor >= low - 0.001 && compositor <= high + 0.001
    }

#if XRIZER_XROS_FIXTURE
    private func loseFixtureSurface() {
        if vx_xros_fixture_enabled() != 0 {
            xrizerFixtureAttempted = true
            xrizerFixtureStarted = false
            let result = vx_xros_fixture_surface_lost()
            vxrt_jlog("xrizer_fixture_surface_lost", "\"result\":\(result),\"resume\":\"unavailable\"")
        }
    }
#endif

    private func loop() {
        let cfg = layerRenderer.configuration
        vxrt_jlog("vr_start", "\"layout\":\"\(cfg.layout)\",\"color\":\(cfg.colorFormat.rawValue),\"depth\":\(cfg.depthFormat.rawValue),\"tracking\":\(tracking)")
        while true {
            switch layerRenderer.state {
            case .invalidated:
#if XRIZER_XROS_FIXTURE
                if xrizerFixtureSurface.invalidated() { loseFixtureSurface() }
#endif
                vxrt_jlog("vr_end", "\"why\":\"layer invalidated\"")
                if let adapter = nativeXRTracking { Task { await adapter.stop() } }
                return
            case .paused:
#if XRIZER_XROS_FIXTURE
                // CompositorServices may initially be paused before its first
                // drawable; only an already started fixture can lose a surface.
                if xrizerFixtureSurface.paused() { loseFixtureSurface() }
#endif
                layerRenderer.waitUntilRunning()
                continue
            default:
                autoreleasepool { frame() }
            }
        }
    }

    private func frame() {
        guard let frame = layerRenderer.queryNextFrame() else { Thread.sleep(forTimeInterval: 0.001); return }
        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        // (no drawables: the system cancelled this frame; ending its submission would abort the app)
        guard !drawables.isEmpty else { return }
        let presentation = Self.seconds(timing.presentationTime)
        if spatialClockCalibrated, let adapter = nativeXRTracking, presentation - lastSpatialSample >= Self.spatialSampleInterval {
            lastSpatialSample = presentation
            Task { await adapter.collect(at: presentation) }
        }
        let anchor = tracking ? trackingGate.read { worldTracking.queryDeviceAnchor(atTimestamp: presentation) } ?? nil : nil
        var head = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let nativeDiagnostic = vx_xros_native_enabled() != 0
#if XRIZER_XROS_FIXTURE
        let fixture = vx_xros_fixture_enabled() != 0
        // -xrizer -immersive: the game's pairs are shown in this space. A two-view dedicated drawable (the headset) gets
        // the stereo path below (each eye of the newest pair warped into its view with the drawable's own view
        // transform and projection); a one-view drawable (the simulator) the side-by-side inspection layout with
        // injected optics. Decided from the drawable the compositor gives, not from the build.
        let immersive = vx_xros_immersive_enabled() != 0
        let stereoDrawable = drawables[0].views.count == 2 && drawables[0].colorTextures.count == 2 && layerRenderer.configuration.layout == .dedicated
        let offscreen = fixture && (ProcessInfo.processInfo.environment["VXRT_XRIZER_XROS_OFFSCREEN"] == "1" || (immersive && !stereoDrawable))
        if immersive && !immersiveLogged {
            immersiveLogged = true
            vx_xros_immersive_set_mono(offscreen ? 1 : 0)
            vxrt_jlog("xrizer_immersive_drawable", "\"views\":\(drawables[0].views.count),\"color_textures\":\(drawables[0].colorTextures.count),\"layout\":\"\(layerRenderer.configuration.layout)\",\"path\":\"\(offscreen ? "mono_inspection_injected_optics" : "stereo_drawable_views")\",\"tracking\":\(tracking)")
        }
        let monoPresent = offscreen && vx_xros_fixture_present_enabled() != 0
        var monoHave: Int32 = 0
        var monoAcquired = false
        if offscreen && !drawables[0].colorTextures.isEmpty && tracking {
            xrizerHeadFrames += 1
            let headTracked: Int32 = anchor?.isTracked == true ? 1 : 0
            if xrizerHeadFrames <= 3 || (headTracked != 0 && !xrizerHeadLogged) {
                let t = head.columns.3
                vxrt_jlog("xrizer_fixture_head", "\"tracked\":\(headTracked),\"present\":\(anchor != nil),\"frame\":\(xrizerHeadFrames),\"x\":\(t.x),\"y\":\(t.y),\"z\":\(t.z)")
                if headTracked != 0 { xrizerHeadLogged = true }
            }
            // Give ARKit a short chance to report a tracked device anchor before
            // the guest consumes its two pairs. An absent anchor stays untracked.
            let readyToOffer = headTracked != 0 || xrizerHeadFrames >= 45
            if readyToOffer && !xrizerFixtureAttempted {
                xrizerFixtureAttempted = true
                if Self.clockMatchesMach() {
                    let device = Unmanaged.passUnretained(layerRenderer.device as AnyObject).toOpaque()
                    let commandQueue = Unmanaged.passUnretained(queue as AnyObject).toOpaque()
                    xrizerFixtureStarted = vx_xros_fixture_start(device, commandQueue) == 0
                        if xrizerFixtureStarted { _ = xrizerFixtureSurface.started() }
                }
                vxrt_jlog("xrizer_offscreen_start", "\"started\":\(xrizerFixtureStarted),\"optics\":\"injected_32mm_pi4\",\"head\":\"device_anchor_or_untracked\",\"controllers\":\"disconnected\"")
            }
            if xrizerFixtureStarted {
                var eyes = [Float](repeating: 0, count: 32)
                for eye in 0..<2 {
                    for j in [0, 5, 10, 15] { eyes[eye * 16 + j] = 1 }
                    eyes[eye * 16 + 12] = eye == 0 ? -0.032 : 0.032
                }
                let frustums: [Float] = [-1, 1, -1, 1, -1, 1, -1, 1]
                let texture = drawables[0].colorTextures[0]
                let offered = eyes.withUnsafeBufferPointer { e in
                    frustums.withUnsafeBufferPointer { f in
                        withUnsafePointer(to: &head) { hp in
                            hp.withMemoryRebound(to: Float.self, capacity: 16) { h in
                                vx_xros_fixture_offer(UInt32(texture.width), UInt32(texture.height), e.baseAddress, f.baseAddress, presentation, headTracked != 0 ? h : nil, headTracked)
                            }
                        }
                    }
                }
                // Inspection: the simulator's one view shows the acquired pair side
                // by side; the fixture audits that drawable's pixels per frame id.
                if monoPresent && offered == 0 && drawables[0].views.count == 1 {
                    monoHave = vx_xros_fixture_present_begin(presentation)
                    monoAcquired = true
                }
                if xrizerFixtureOffscreenOffers < 2 {
                    xrizerFixtureOffscreenOffers += 1
                    if xrizerFixtureOffscreenOffers == 1 {
                        let depthCount = drawables[0].depthTextures.count
                        vxrt_jlog("xrizer_offscreen_drawable", "\"views\":\(drawables[0].views.count),\"color_textures\":\(drawables[0].colorTextures.count),\"depth_textures\":\(depthCount),\"color_w\":\(texture.width),\"color_h\":\(texture.height),\"layout_raw\":\(layerRenderer.configuration.layout.rawValue)")
                    }
                    vxrt_jlog("xrizer_offscreen_sample", "\"result\":\(offered),\"sample\":\(xrizerFixtureOffscreenOffers)")
                }
            }
        }
#else
        let fixture = false
        let offscreen = false
        let monoHave: Int32 = 0
        let monoAcquired = false
#endif
        let native = nativeDiagnostic || (fixture && !offscreen) || monoAcquired
        var have: Int32 = monoHave
        if native && !monoAcquired {
            let d = drawables[0]
            var eyes = [Float](repeating: 0, count: 32)
            var frustums = [Float](repeating: 0, count: 8)
            var dedicated = layerRenderer.configuration.layout == .dedicated && d.colorTextures.count == 2
            if dedicated {
                let l = d.colorTextures[0], r = d.colorTextures[1]
                dedicated = l.width == r.width && l.height == r.height
                if dedicated && !fixture { _ = vx_xros_native_set_render_size(UInt32(l.width), UInt32(l.height)) }
            }
            if d.views.count == 2 && dedicated {
                for i in 0..<2 {
                    var transform = d.views[i].transform
                    withUnsafePointer(to: &transform) { ptr in
                        ptr.withMemoryRebound(to: Float.self, capacity: 16) { p in
                            for j in 0..<16 { eyes[i * 16 + j] = p[j] }
                        }
                    }
                    let p = d.computeProjection(convention: .rightUpBack, viewIndex: i)
                    frustums[i * 4] = -(1 - p.columns.2.x) / p.columns.0.x
                    frustums[i * 4 + 1] = (1 + p.columns.2.x) / p.columns.0.x
                    frustums[i * 4 + 2] = -(1 + p.columns.2.y) / p.columns.1.y
                    frustums[i * 4 + 3] = (1 - p.columns.2.y) / p.columns.1.y
                }
            }
#if XRIZER_XROS_FIXTURE
            if fixture {
                if !xrizerFixtureObserved {
                    xrizerFixtureObserved = true
                    vxrt_jlog("xrizer_fixture_drawable", "\"views\":\(d.views.count),\"color_textures\":\(d.colorTextures.count),\"dedicated\":\(dedicated)")
                }
                if !xrizerFixtureAttempted && dedicated && d.views.count == 2 {
                    xrizerFixtureAttempted = true
                    if Self.clockMatchesMach() {
                        let device = Unmanaged.passUnretained(layerRenderer.device as AnyObject).toOpaque()
                        let commandQueue = Unmanaged.passUnretained(queue as AnyObject).toOpaque()
                        xrizerFixtureStarted = vx_xros_fixture_start(device, commandQueue) == 0
                        if xrizerFixtureStarted { _ = xrizerFixtureSurface.started() }
                    }
                    vxrt_jlog("xrizer_fixture_start", "\"started\":\(xrizerFixtureStarted),\"head\":\"device_anchor_or_untracked\",\"controllers\":\"disconnected\"")
                }
                if xrizerFixtureStarted && dedicated && d.views.count == 2 {
                    let texture = d.colorTextures[0]
                    let headTracked: Int32 = anchor?.isTracked == true ? 1 : 0
                    let offered = eyes.withUnsafeBufferPointer { e in
                        frustums.withUnsafeBufferPointer { f in
                            withUnsafePointer(to: &head) { hp in
                                hp.withMemoryRebound(to: Float.self, capacity: 16) { h in
                                    vx_xros_fixture_offer(UInt32(texture.width), UInt32(texture.height), e.baseAddress, f.baseAddress, presentation, headTracked != 0 ? h : nil, headTracked)
                                }
                            }
                        }
                    }
                    if offered == 0 { have = vx_xros_fixture_present_begin(presentation) }
                }
            }
#endif
            if !fixture {
            let controllers = trackingGate.read { nativeInput.controllers() } ?? [vx_native_openvr_controller(), vx_native_openvr_controller()]
            have = withUnsafePointer(to: &head) { hp in
                hp.withMemoryRebound(to: Float.self, capacity: 16) { h in
                    eyes.withUnsafeBufferPointer { e in
                        frustums.withUnsafeBufferPointer { f in
                            controllers.withUnsafeBufferPointer { c in
                                vx_xros_native_begin(h, e.baseAddress, f.baseAddress, presentation,
                                                     anchor?.isTracked == true && d.views.count == 2 && dedicated ? 1 : 0,
                                                     c.baseAddress)
                            }
                        }
                    }
                }
            }
            }
        } else if !native {
            have = withUnsafePointer(to: &head) {
                $0.withMemoryRebound(to: Float.self, capacity: 16) { vx_xros_vr_begin_frame($0, presentation) }
            }
        }
        guard let cb = queue.makeCommandBuffer() else {
            if native { vx_xros_native_end(nil) } else { vx_xros_vr_end_frame(nil) }
            frame.endSubmission(); return
        }
        cb.label = "VX eyes"
        let cbp = Unmanaged.passUnretained(cb as AnyObject).toOpaque()
        for d in drawables {
            d.deviceAnchor = anchor
            d.depthRange = SIMD2<Float>(Self.far, Self.near)
            for i in d.views.indices {
                let color = d.colorTextures[min(i, d.colorTextures.count - 1)]
                let depth = d.depthTextures[min(i, d.depthTextures.count - 1)]
                var ok: Int32 = 0
                if have != 0 {
                    var viewFromOrigin = (head * d.views[i].transform).inverse
                    // the eye's frustum from its projection (right-up-back: x_ndc = (P00 x + P20 z) / -z)
                    let p = d.computeProjection(convention: .rightUpBack, viewIndex: i)
                    var tan = SIMD4<Float>((1 - p.columns.2.x) / p.columns.0.x, (1 + p.columns.2.x) / p.columns.0.x,
                                           (1 + p.columns.2.y) / p.columns.1.y, (1 - p.columns.2.y) / p.columns.1.y)
                    ok = withUnsafePointer(to: &viewFromOrigin) { vp in
                        vp.withMemoryRebound(to: Float.self, capacity: 16) { v in
                            withUnsafePointer(to: &tan) { tp in
                                tp.withMemoryRebound(to: Float.self, capacity: 4) { t in
                                    let colorp = Unmanaged.passUnretained(color as AnyObject).toOpaque()
                                    let depthp = Unmanaged.passUnretained(depth as AnyObject).toOpaque()
#if XRIZER_XROS_FIXTURE
                                    if monoAcquired { return vx_xros_fixture_draw_inspection(cbp, Int32(i), colorp, depthp) }
#endif
                                    if native { return vx_xros_native_draw_eye(cbp, Int32(i), v, t, colorp, depthp) }
                                    return vx_xros_vr_draw_eye(cbp, Int32(i), v, t, Self.near, colorp, depthp)
                                }
                            }
                        }
                    }
                }
                if ok == 0 { clear(cb, color, depth) }
            }
            d.encodePresent(commandBuffer: cb)
        }
        if native { vx_xros_native_end(cbp) } else { vx_xros_vr_end_frame(cbp) }
        cb.commit()
        frame.endSubmission()
        report()
    }

    // (no game frame yet: a dark grey room, depth far)
    private func clear(_ cb: MTLCommandBuffer, _ color: MTLTexture, _ depth: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        cleared += 1
    }

    private func report() {
        let now = CACurrentMediaTime()
        guard now - lastReport >= 1 else { return }
        lastReport = now
        var buf = [CChar](repeating: 0, count: 768)
        vx_xros_vr_stats(&buf, UInt32(buf.count))
        var fields = String(cString: buf) + ",\"cleared_eyes\":\(cleared)"
#if XRIZER_XROS_FIXTURE
        if vx_xros_immersive_enabled() != 0 {
            var imm = [CChar](repeating: 0, count: 768)
            _ = vx_xros_immersive_stats(&imm, UInt32(imm.count))
            fields += "," + String(cString: imm)
        }
#endif
        cleared = 0
        vxrt_jlog("vr", fields)
    }
}
