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
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

final class VXImmersiveRenderer: @unchecked Sendable {
    private let layerRenderer: LayerRenderer
    private let queue: MTLCommandQueue
    // The previous renderer when the compositor layer was invalidated and the immersive space reopened: ARKit (the head session, the
    // Sense accessory session) and the xrizer provider carry on; only the layer, its queue and its loop are new.
    nonisolated(unsafe) private static var previous: VXImmersiveRenderer?
    private let arSession: ARKitSession
    private let worldTracking: WorldTrackingProvider
    private let trackingGate: VXTrackingGate
    private let nativeInput: VXNativeInput
    private var tracking = false
    private var presentationIntervalSum = 0.0, presentationIntervalCount = 0, lastPresentationTime = 0.0
    private var fixtureMsMax = 0.0
    private var lastHead = matrix_identity_float4x4
    private var lastReport = CACurrentMediaTime()
    private var cleared = 0
    // per-second frame diagnostics (the device kills an immersive app that stops presenting; run 2 died with no trace)
    nonisolated(unsafe) static var frameCount: UInt64 = 0
    nonisolated(unsafe) static var lastFrameUptime = 0.0
    private var anchorPresent = 0, anchorTracked = 0, anchorMissing = 0, framesSecond = 0
    private var submitMsSum = 0.0, submitMsMax = 0.0, inputWaitMsMax = 0.0
    private var placeholderMarker: MTLBuffer?
    // Self-capture of what the compositor draws (devicectl cannot screenshot a visionOS device): every VXRT_SHOT_EVERY seconds (default 8;
    // 0 = off) the finished left and right drawable textures are copied to shared buffers on the GPU; the completion handler logs their mean
    // colour (`output_probe`) and writes a quarter-size PNG to Documents/shots/ (shot_L.png, shot_R.png, overwritten, and a numbered copy).
    private var shotNext = 0.0, shotCount = 0
    private static let shotEvery: Double = {
        if let e = ProcessInfo.processInfo.environment["VXRT_SHOT_EVERY"], let d = Double(e) { return d }
        return 8
    }()
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
        let prior = previous
        let r = VXImmersiveRenderer(layerRenderer, q, previous: prior)
        previous = r
        if prior != nil {
            vxrt_jlog("vr_rebind", "\"what\":\"new compositor layer on the running session\",\"tracking\":\(r.tracking),\"fixture_started\":\(r.fixtureStartedForLog)")
            let thread = Thread { r.loop() }
            thread.name = "VX compositor"
            thread.qualityOfService = .userInteractive
            thread.start()
            return
        }
        // The compositor loop first and on its own thread, as Klepton does (KleptonCompositor.renderLoop: waitUntilRunning,
        // then ARKit beside it): nothing about ARKit, its permission prompts or a session re-run may hold the frames back.
        // (Device run 1: the loop waited for the accessory session; the loader gave up after 30 s.)
        let thread = Thread { r.loop() }
        thread.name = "VX compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
        Task {
            guard WorldTrackingProvider.isSupported else { return }
            // Sense controllers (accessory tracking) whenever the immersive space is open: the native diagnostic
            // (VXRT_NATIVE_VR) or the xrizer fixture/game (-immersive). Hands stay with the native path.
            var controllersWanted = vx_xros_native_enabled() != 0
            var singleRun = false
#if XRIZER_XROS_FIXTURE
            if vx_xros_fixture_enabled() != 0 { controllersWanted = true; singleRun = vx_xros_native_enabled() == 0 }
#endif
            // xrizer path: ONE ARKit run with the head and the controllers (Klepton's runARKit: world, hands, accessories
            // in a single session.run), not a head-only run followed by a second one that pauses the head's queries.
            if singleRun {
                r.spatialClockCalibrated = Self.clockMatchesMach()
                if r.spatialClockCalibrated {
                    // The head in its own session first (the loop and the game's poses depend on it), then the Sense controllers in
                    // a second ARKitSession: the same ARKit world origin (Klepton's room planes use a second session too), and a
                    // controller run that blocks leaves the head alone. (Device run 4: one combined run never returned.)
                    do { try await r.arSession.run([r.worldTracking]); r.tracking = true; vxrt_jlog("head_session", "\"what\":\"running\"") }
                    catch { vxrt_jlog("vr_error", "\"what\":\"world tracking: \(error.localizedDescription)\"") }
                    let adapter = VXNativeXRTracking(session: ARKitSession(), world: r.worldTracking, hands: nil, gate: r.trackingGate, accessoryOnly: true)
                    r.nativeXRTracking = adapter
                    await adapter.start()
                    return
                }
                vxrt_jlog("vr_error", "\"what\":\"spatial clock calibration failed\"")
                controllersWanted = false
            }
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
                if controllersWanted {
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
    }

    private init(_ layerRenderer: LayerRenderer, _ queue: MTLCommandQueue, previous: VXImmersiveRenderer?) {
        self.layerRenderer = layerRenderer
        self.queue = queue
        queue.label = "VX compositor"
        arSession = previous?.arSession ?? ARKitSession()
        worldTracking = previous?.worldTracking ?? WorldTrackingProvider()
        trackingGate = previous?.trackingGate ?? VXTrackingGate()
        nativeInput = previous?.nativeInput ?? VXNativeInput()
        if let p = previous {
            tracking = p.tracking
            nativeXRTracking = p.nativeXRTracking
            spatialClockCalibrated = p.spatialClockCalibrated
#if XRIZER_XROS_FIXTURE
            xrizerFixtureAttempted = p.xrizerFixtureAttempted
            xrizerFixtureStarted = p.xrizerFixtureStarted
            xrizerFixtureSurface = p.xrizerFixtureSurface
            xrizerHeadLogged = true
            immersiveLogged = true
#endif
        }
    }
    var fixtureStartedForLog: Bool {
#if XRIZER_XROS_FIXTURE
        return xrizerFixtureStarted
#else
        return false
#endif
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
                // The system ended the compositor layer (not our decision). Reopen the immersive space with a new layer and
                // keep the provider, ARKit and the game running; only when the reopen budget is spent does the surface count as lost.
                let reopening = VXLifecycle.layerInvalidated()
                vxrt_jlog("vr_end", "\"why\":\"layer invalidated\",\"reopening\":\(reopening),\"frames\":\(Self.frameCount)")
                if !reopening {
#if XRIZER_XROS_FIXTURE
                    if xrizerFixtureSurface.invalidated() { loseFixtureSurface() }
#endif
                    VXLifecycle.outputEnded = true
                    if let adapter = nativeXRTracking { Task { await adapter.stop() } }
                }
                return
            case .paused:
                // Klepton's csFrames: a paused layer (a system alert such as the motion-input prompt, the crown's peek) is waited out
                // and the loop carries on. It is NOT a lost surface: the old code stopped the xrizer provider for good on the first
                // pause, which xrizer answers with a panic once the game asks for a size. Only an invalidated layer ends this loop.
                vxrt_jlog("vr_pause", "\"frames\":\(Self.frameCount)")
                layerRenderer.waitUntilRunning()
                vxrt_jlog("vr_resume", "\"frames\":\(Self.frameCount)")
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
        let waitStart = CACurrentMediaTime()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        let waited = (CACurrentMediaTime() - waitStart) * 1000
        if waited > inputWaitMsMax { inputWaitMsMax = waited }
        // Klepton's order (KleptonCompositor.renderFrame, Apple's template): queryDrawables, THEN startSubmission. A frame
        // abandoned before startSubmission is not an open submission; the old order opened it first and walked away
        // from it when there was no drawable.
        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }
        guard let cb = queue.makeCommandBuffer() else { return }
        let submitStart = CACurrentMediaTime()
        frame.startSubmission()
        let presentation = Self.seconds(timing.presentationTime)
        if lastPresentationTime > 0 { presentationIntervalSum += presentation - lastPresentationTime; presentationIntervalCount += 1 }
        lastPresentationTime = presentation
        let fixtureStart = CACurrentMediaTime()
        defer { let ms = (CACurrentMediaTime() - fixtureStart) * 1000; if ms > fixtureMsMax { fixtureMsMax = ms } }
        if spatialClockCalibrated, let adapter = nativeXRTracking, presentation - lastSpatialSample >= Self.spatialSampleInterval {
            lastSpatialSample = presentation
            Task { await adapter.collect(at: presentation) }
        }
        let anchor = tracking ? trackingGate.read { worldTracking.queryDeviceAnchor(atTimestamp: presentation) } ?? nil : nil
        if tracking {
            if let a = anchor { anchorPresent += 1; if a.isTracked { anchorTracked += 1 } } else { anchorMissing += 1 }
        }
        if Self.frameCount < 8 {
            vxrt_jlog("frame_trace", "\"n\":\(Self.frameCount),\"drawables\":\(drawables.count),\"anchor\":\(anchor != nil),\"anchor_tracked\":\(anchor?.isTracked == true),\"input_wait_ms\":\(String(format: "%.2f", waited))")
        }
        var head = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        if anchor != nil { lastHead = head }
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
                if ok != 0 { Self.shownGamePair = true } else { clear(cb, color, depth) }
            }
            captureOutput(cb, d)
            d.encodePresent(commandBuffer: cb)
        }
        if native { vx_xros_native_end(cbp) } else { vx_xros_vr_end_frame(cbp) }
        cb.commit()
        frame.endSubmission()
        let took = (CACurrentMediaTime() - submitStart) * 1000
        submitMsSum += took; if took > submitMsMax { submitMsMax = took }
        framesSecond += 1
        Self.frameCount &+= 1
        Self.lastFrameUptime = CACurrentMediaTime()
        report()
    }

    private func captureOutput(_ cb: MTLCommandBuffer, _ d: LayerRenderer.Drawable) {
        guard Self.shotEvery > 0 else { return }
        let now = CACurrentMediaTime()
        guard now >= shotNext, !d.colorTextures.isEmpty else { return }
        shotNext = now + Self.shotEvery
        shotCount += 1
        let n = shotCount
        for i in 0..<min(2, d.views.count) {
            let tex = d.colorTextures[min(i, d.colorTextures.count - 1)]
            guard !tex.isFramebufferOnly, tex.pixelFormat == .bgra8Unorm_srgb || tex.pixelFormat == .bgra8Unorm, tex.textureType == .type2D || tex.textureType == .type2DArray else { continue }
            let w = tex.width, h = tex.height, bpr = w * 4
            guard let buf = cb.device.makeBuffer(length: bpr * h, options: .storageModeShared), let blit = cb.makeBlitCommandEncoder() else { continue }
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
            blit.endEncoding()
            let name = i == 0 ? "L" : "R"
            cb.addCompletedHandler { _ in
                // mean colour of a 16 x 16 grid of the bytes as stored (sRGB-encoded for the srgb format: what is shown)
                var sum = (0, 0, 0), points = 0, mx = 0
                let p = buf.contents().assumingMemoryBound(to: UInt8.self)
                for gy in 0..<16 { for gx in 0..<16 {
                    let o = ((h - 1) * (gy * 2 + 1) / 32) * bpr + ((w - 1) * (gx * 2 + 1) / 32) * 4
                    sum.0 += Int(p[o + 2]); sum.1 += Int(p[o + 1]); sum.2 += Int(p[o]); points += 1
                    mx = max(mx, Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))
                } }
                vxrt_jlog("output_probe", "\"n\":\(n),\"eye\":\"\(name)\",\"w\":\(w),\"h\":\(h),\"mean_rgb\":[\(sum.0 / points),\(sum.1 / points),\(sum.2 / points)],\"max\":\(mx)")
                // a quarter-size PNG
                let sw = w / 4, sh = h / 4
                guard let provider = CGDataProvider(data: Data(bytes: p, count: bpr * h) as CFData),
                      let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let full = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr, space: space,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                      let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
                ctx.interpolationQuality = .medium
                ctx.draw(full, in: CGRect(x: 0, y: 0, width: sw, height: sh))
                guard let small = ctx.makeImage() else { return }
                let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/shots")
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                for file in ["shot_\(name).png", String(format: "shot_%03d_\(name).png", n % 100)] {
                    let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(file)) as CFURL
                    if let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, small, nil); CGImageDestinationFinalize(dest)
                    }
                }
            }
        }
    }

    // (no game frame yet: a mid grey-blue that pulses slowly, so the wearer can tell the app is alive, and a head-locked
    // light square in the middle of each eye. Depth far.)
    nonisolated(unsafe) static var shownGamePair = false
    private func clear(_ cb: MTLCommandBuffer, _ color: MTLTexture, _ depth: MTLTexture) {
        // Once a game pair has been shown the placeholder never comes back (a hitch, a stale pair, a swapchain change): black, at the
        // finite depth. Before the first pair: the pulsing blue and the marker.
        if Self.shownGamePair {
            let hold = MTLRenderPassDescriptor()
            hold.colorAttachments[0].texture = color; hold.colorAttachments[0].loadAction = .clear
            hold.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1); hold.colorAttachments[0].storeAction = .store
            hold.depthAttachment.texture = depth; hold.depthAttachment.loadAction = .clear; hold.depthAttachment.clearDepth = 0.05
            hold.depthAttachment.storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: hold)?.endEncoding()
            cleared += 1
            return
        }
        let pulse = 0.5 + 0.5 * sin(CACurrentMediaTime() * 2 * Double.pi / 3)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.10 + 0.06 * pulse, green: 0.20 + 0.08 * pulse, blue: 0.40 + 0.15 * pulse, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        // 0.05 (reverse-Z, about 2 m), not 0: a depth of 0 everywhere is "nothing at any finite distance" and the system does not show the
        // colour (Klepton, measured on device). This was why the placeholder, and every game frame, was never seen.
        pass.depthAttachment.clearDepth = 0.05
        pass.depthAttachment.storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        // the marker: a 160 x 160 square copied from a buffer (no pipeline needed); the texture is bgra8 (srgb)
        let side = 512
        if color.width >= side * 2, color.height >= side * 2, color.pixelFormat == .bgra8Unorm_srgb || color.pixelFormat == .bgra8Unorm {
            if placeholderMarker == nil {
                var pixels = [UInt8](repeating: 0, count: side * side * 4)
                for y in 0..<side { for x in 0..<side {
                    let border = x < 8 || y < 8 || x >= side - 8 || y >= side - 8
                    let v: UInt8 = border ? 255 : 200
                    let i = (y * side + x) * 4
                    pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = border ? 255 : 230; pixels[i + 3] = 255
                } }
                placeholderMarker = layerRenderer.device.makeBuffer(bytes: pixels, length: pixels.count, options: .storageModeShared)
            }
            if let buf = placeholderMarker, let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: buf, sourceOffset: 0, sourceBytesPerRow: side * 4, sourceBytesPerImage: side * side * 4,
                          sourceSize: MTLSize(width: side, height: side, depth: 1), to: color, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: color.width / 2 - side / 2, y: color.height / 2 - side / 2, z: 0))
                blit.endEncoding()
            }
        }
        cleared += 1
    }

    // Once a second: the head and both controllers in the SAME frame, in the provider's local space (each from its own ARKit session) and
    // after the stage transform, plus the controller-to-head distance (an origin mismatch between the two sessions shows as a distance
    // no arm can make). Also teed to the console.
    private func poseAudit(head: simd_float4x4) {
#if XRIZER_XROS_FIXTURE
        var st = [Float](repeating: 0, count: 7)
        let staged = vx_xros_fixture_stage(&st) != 0
        let q = simd_quatf(ix: st[3], iy: st[4], iz: st[5], r: st[6])
        func toStage(_ p: SIMD3<Float>) -> SIMD3<Float> { q.inverse.act(p - SIMD3(st[0], st[1], st[2])) }
        func f(_ v: SIMD3<Float>?) -> String { v.map { String(format: "[%.3f,%.3f,%.3f]", $0.x, $0.y, $0.z) } ?? "null" }
        let h = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let c = VXPoseAudit.shared.get()
        func dist(_ p: SIMD3<Float>?) -> String { p.map { String(format: "%.3f", simd_length($0 - h)) } ?? "null" }
        let line = "\"head_local\":\(f(h)),\"grip_local\":[\(f(c.grip[0])),\(f(c.grip[1]))],\"aim_local\":[\(f(c.aim[0])),\(f(c.aim[1]))],\"stage\":\(staged),\"head_stage\":\(staged ? f(toStage(h)) : "null"),\"grip_stage\":[\(staged ? f(c.grip[0].map(toStage)) : "null"),\(staged ? f(c.grip[1].map(toStage)) : "null")],\"grip_to_head_m\":[\(dist(c.grip[0])),\(dist(c.grip[1]))]"
        vxrt_jlog("pose_audit", line)
        print("pose_audit \(line)")
#endif
    }

    private func report() {
        let now = CACurrentMediaTime()
        guard now - lastReport >= 1 else { return }
        lastReport = now
        poseAudit(head: lastHead)
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
        fields += ",\"presentation_interval_ms\":\(String(format: "%.2f", presentationIntervalCount > 0 ? presentationIntervalSum / Double(presentationIntervalCount) * 1000 : 0)),\"frame_total_ms_max\":\(String(format: "%.2f", fixtureMsMax))"
        presentationIntervalSum = 0; presentationIntervalCount = 0; fixtureMsMax = 0
        fields += ",\"frames\":\(framesSecond),\"anchor_present\":\(anchorPresent),\"anchor_tracked\":\(anchorTracked),\"anchor_missing\":\(anchorMissing),\"submit_ms_mean\":\(String(format: "%.2f", framesSecond > 0 ? submitMsSum / Double(framesSecond) : 0)),\"submit_ms_max\":\(String(format: "%.2f", submitMsMax)),\"input_wait_ms_max\":\(String(format: "%.2f", inputWaitMsMax))"
        framesSecond = 0; anchorPresent = 0; anchorTracked = 0; anchorMissing = 0; submitMsSum = 0; submitMsMax = 0; inputWaitMsMax = 0
        vxrt_jlog("vr", fields)
    }
}
