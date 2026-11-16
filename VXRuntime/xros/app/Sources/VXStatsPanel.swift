// The performance panel in the headset: how the game is running, as the numbers of the last second and the graphs of the last minute,
// fixed to the head above the middle of the view. Create and Options (the two menu buttons of the Sense controllers) held together for a
// second show it and hide it, as in every game AVP Play builds with Klepton, and the game must not open its menu for that.
//
// Adapted from Klepton (MIT, Copyright (c) 2026 Max Thomas and contributors; fork https://github.com/myMartek/Klepton, tag toolchain-890; license
// text third_party/klepton_openxr/LICENSE): the button logic is runtime/diag/kl_metrics.c kl_metrics_chord, the idea and the placement
// visionos/Sources/KleptonCompositor.swift (the metrics panel, KL_STATS_CARD), the drawing KleptonMetrics.swift (copied beside this file).
// Different here: the panel is a quad of its own pass over each eye's finished picture (VXOverlay.swift; through the drawable's rate
// map if it has one), because this app's eye images are written by the runtime's presenter; and the samples come from the
// records the app logs once a second anyway (VXImmersive.report).
//
// A meter must not be what it measures: until the panel is first shown nothing of it exists; the picture is drawn once a second on a
// queue of its own into the buffer no frame is reading, and a frame only copies it.
import CoreGraphics
import CoreText
import Foundation
import Metal
import QuartzCore
import simd

// The two buttons' logic, apart from the drawing so that it is tested on the Mac (tests/xros_stats_chord_test.swift).
// Each button is in one of five states. A press waits (pending) before it is passed on (passing), because whether it is the first half
// of "both together" is only known a moment later, and a game that has been told "menu" has already opened it. A press that ends while
// it waits was a tap and is played afterwards (tap). Both down is chord for both, and stays that until both are up: letting one go must
// not turn the other into a press of its own.
struct VXMenuChord {
    static let wait = 0.25      // how long a press waits for the other button
    static let tap = 0.10       // how long a tap is played once it is known to be one
    static let hold = 1.0       // how long both are held to switch the panel
    private enum Phase { case idle, pending, passing, tap, chord }
    private var phase: [Phase] = [.idle, .idle]
    private var since: [Double] = [0, 0]
    private var chordSince = 0.0
    private var chordSpent = false          // switched already, or one of the two was let go

    /// One poll: which of the two buttons is down now. Returns whether each is passed on to the game, and whether this poll switched
    /// the panel (both held for `hold` without a gap).
    mutating func poll(left: Bool, right: Bool, now: Double) -> (passLeft: Bool, passRight: Bool, switched: Bool) {
        let down = [left, right]
        var switched = false
        if left && right {
            if phase[0] != .chord {
                phase = [.chord, .chord]
                chordSince = now; chordSpent = false
            } else if !chordSpent && now - chordSince >= Self.hold {
                chordSpent = true
                switched = true
            }
        } else if phase[0] == .chord {
            chordSpent = true                 // held together means without a gap
            if !left && !right { phase = [.idle, .idle] }
        }
        for h in 0..<2 {
            switch phase[h] {
            case .idle: if down[h] { phase[h] = .pending; since[h] = now }
            case .pending:
                if !down[h] { phase[h] = .tap; since[h] = now } else if now - since[h] >= Self.wait { phase[h] = .passing }
            case .passing: if !down[h] { phase[h] = .idle }
            case .tap: if now - since[h] >= Self.tap { phase[h] = .idle }
            case .chord: break
            }
        }
        func pass(_ h: Int) -> Bool { phase[h] == .passing || phase[h] == .tap }
        return (pass(0), pass(1), switched)
    }
}

#if !VX_CHORD_TEST
final class VXStatsPanel {
    static let shared = VXStatsPanel()
    /// VXRT_STATS_CARD_BUTTONS=0 (or Klepton's KL_STATS_CARD_BUTTONS) hands the two buttons to the game untouched.
    static let buttons: Bool = {
        let env = ProcessInfo.processInfo.environment
        return (env["VXRT_STATS_CARD_BUTTONS"] ?? env["KL_STATS_CARD_BUTTONS"]) != "0"
    }()
    /// The panel's size and place in the view, exactly Klepton's (KLMetricsPanel.panelSize and the pose in KleptonCompositor.swift, "the
    /// owner's place for it, found in three tries on the headset"): 0.338 m wide at 1.2 m, just left of the middle, its lower edge a
    /// little above it.
    static let widthMeters: Float = KLMetricsPanel.panelSize.x, distanceMeters: Float = 1.2
    static let offsetMeters = SIMD2<Float>(-0.05, 0.101)

    private let lock = NSLock()
    private var chord = VXMenuChord()
    private var shown = false
    private var samples: [KLMetricsSample] = []
    private var front: MTLTexture?, back: MTLTexture?   // two, swapped when the new picture is complete: a frame never samples the one being written
    private var size = (w: 0, h: 0)                 // of front and back
    private var wanted = (w: 0, h: 0)
    private var device: MTLDevice?
    private var drawing = false
    private let queue = DispatchQueue(label: "vxrt.metrics", qos: .utility)
    private let quad = VXOverlayQuad()

    var visible: Bool { lock.lock(); defer { lock.unlock() }; return shown }

    /// Shows or hides the panel (the setting "from the start", and the chord). Shown anew, it starts measuring from there.
    func setVisible(_ on: Bool, why: String) {
        lock.lock()
        let changed = shown != on
        shown = on
        if changed && on { samples.removeAll() }
        lock.unlock()
        guard changed else { return }
        // Until the panel is first shown nothing of it exists: no count of the GPU's command buffers either.
        var counting = false
        if on { counting = vx_gpu_busy_install() != 0; _ = vx_gpu_busy_take(nil); vx_gpu_compiles_take(nil, nil); lastSample = CACurrentMediaTime() }
        vxrt_jlog("stats_panel", "\"shown\":\(on),\"why\":\"\(why)\",\"gpu_counted\":\(counting)")
        if on { redraw() }
    }

    /// The two menu buttons as read this poll; returns what the game is told of each.
    func buttons(left: Bool, right: Bool, now: Double) -> (left: Bool, right: Bool) {
        guard Self.buttons else { return (left, right) }
        lock.lock()
        let r = chord.poll(left: left, right: right, now: now)
        let next = r.switched ? !shown : shown
        lock.unlock()
        if r.switched { setVisible(next, why: "create+options") }
        return (r.passLeft, r.passRight)
    }

    /// One second of how the game ran (VXImmersive.report). Kept only while the panel is shown.
    func note(_ sample: KLMetricsSample) {
        lock.lock()
        guard shown else { lock.unlock(); return }
        samples.append(sample)
        if samples.count > KLMetricsPanel.history { samples.removeFirst(samples.count - KLMetricsPanel.history) }
        lock.unlock()
        redraw()
    }

    private func redraw() {
        lock.lock()
        guard !drawing, wanted.w > 0, let device = device else { lock.unlock(); return }
        drawing = true
        let want = wanted, list = samples
        var target = size.w == want.w && size.h == want.h ? back : nil
        lock.unlock()
        queue.async { [self] in
            if target == nil { target = VXOverlayQuad.makeTexture(device, width: want.w, height: want.h) }
            if let tex = target { Self.render(list, into: tex, width: want.w, height: want.h) }
            lock.lock()
            if let tex = target {
                if size.w != want.w || size.h != want.h { front = tex; back = nil; size = want }   // a new size: the other one follows on the next turn
                else { back = front; front = tex }
            }
            drawing = false
            lock.unlock()
        }
    }

    private static func render(_ samples: [KLMetricsSample], into tex: MTLTexture, width w: Int, height h: Int) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
              let data = ctx.data else { return }
        // KLMetricsPanel draws top-down on its layout units (KLMetricsPanel.makeContext does the same for its own bitmap).
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        let unit = CGFloat(w) / CGFloat(KLMetricsPanel.panelLayout.w)
        ctx.scaleBy(x: unit, y: unit)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        KLMetricsPanel.drawPanel(ctx, samples: samples)
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
    }

    /// Draws the panel over `color` where a point above straight ahead falls in this eye. `view` is the drawable's eye transform (head
    /// from eye), `projection` its projection (right-up-back), `map` and `viewport` the eye's (VXDisplay.raster). Nothing happens while
    /// the panel is hidden or not drawn yet.
    func encode(cb: MTLCommandBuffer, color: MTLTexture, view: simd_float4x4, projection: simd_float4x4,
                map: MTLRasterizationRateMap?, viewport: MTLViewport) {
        let shape = SIMD2<Float>(Self.widthMeters, Self.widthMeters * Float(KLMetricsPanel.panelLayout.h) / Float(KLMetricsPanel.panelLayout.w))
        let displayWidth = map != nil && viewport.width > 0 ? viewport.width : Double(color.width)
        guard let at = VXOverlayQuad.place(size: shape, distance: Self.distanceMeters, offset: Self.offsetMeters, view: view,
                                           projection: projection, displayWidth: displayWidth) else { return }
        // as many pixels as the panel gets on the display, up to the size it is laid out on
        let w = min(max(at.pixels & ~1, 240), KLMetricsPanel.panelPixels.w)
        let h = w * KLMetricsPanel.panelLayout.h / KLMetricsPanel.panelLayout.w
        lock.lock()
        guard shown else { lock.unlock(); return }
        let fresh = wanted.w != w || wanted.h != h || device == nil
        if fresh { wanted = (w, h); device = cb.device }
        let tex = front
        lock.unlock()
        if fresh || tex == nil { redraw() }
        guard let tex = tex else { return }
        quad.draw(cb: cb, color: color, texture: tex, centre: at.centre, half: at.half, map: map, viewport: viewport)
    }

    // ---- the sample ------------------------------------------------------------------------------------------------------------

    /// A number out of the app's once-a-second records (JSON fields without braces).
    static func number(_ key: String, in fields: String) -> Double? {
        guard let r = fields.range(of: "\"\(key)\":") else { return nil }
        let tail = fields[r.upperBound...]
        let text = tail.prefix { "-+.0123456789eE".contains($0) }
        return Double(text)
    }

    private var lastSample = CACurrentMediaTime()
    /// CPU the process used since the last call, in cores, and the busiest thread's share of one core with its name.
    private func cpu() -> (cores: Float, top: Float, name: String) {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let list = threads else { return (-1, -1, "") }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)) }
        var total = 0.0, top = 0.0, name = ""
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var n = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &n) } }
            if kr == KERN_SUCCESS && info.flags & TH_FLAGS_IDLE == 0 {
                let share = Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
                total += share
                if share > top {
                    top = share
                    var buf = [CChar](repeating: 0, count: 64)
                    if let pt = pthread_from_mach_thread_np(list[i]), pthread_getname_np(pt, &buf, buf.count) == 0 { name = String(cString: buf) } else { name = "" }
                }
            }
            mach_port_deallocate(mach_task_self_, list[i])
        }
        return (Float(total), Float(min(top, 1)), name)
    }

    private func memory() -> (used: Int, left: Int) {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        let used = kr == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
        return (used, Int(os_proc_available_memory() >> 20))
    }

    /// Builds the second's sample from the records VXImmersive.report has just made: `vr` (the compositor's and the presenter's counts),
    /// `timing` (the gate's and the compositor frames' times), and the size of the eye image the display gets. Called once a second on the frame thread;
    /// does nothing while the panel is hidden.
    func sample(vr: String, timing: String, frames: Int, drawable: (w: Int, h: Int)) {
        guard visible else { return }
        var s = KLMetricsSample()
        s.fps = Float(Self.number("imm_interval_fresh", in: vr) ?? 0)
        s.displayHz = Float(frames)
        let now = CACurrentMediaTime(), dt = max(now - lastSample, 0.25)
        lastSample = now
        // Shaders and pipeline states asked of Metal this second (VXGpuBusy.m), compiled or only fetched.
        var compiled: UInt = 0, cached: UInt = 0
        vx_gpu_compiles_take(&compiled, &cached)
        s.compiles = Float(Double(compiled) / dt); s.compilesCached = Float(Double(cached) / dt)
        let compMs = Self.number("cf_gpu_ms_mean", in: timing) ?? 0, compFrames = Self.number("cf_frames", in: timing) ?? 0
        if compMs > 0 { s.gpuCompMs = Float(compMs) }
        // The GPU's working time for the app, as Klepton's panel has it (kl_metrics.c): against the wall clock a utilization; less the
        // display's share and over the game's frames, the GPU time of a game frame.
        let busy = vx_gpu_busy_take(nil)
        if busy >= 0 {
            s.gpuBusy = Float(min(busy / dt, 1))
            let game = busy - compMs * compFrames / 1000
            if s.fps >= 1, game > 0 { s.gpuGameMs = Float(game / Double(s.fps) * 1000) }
        } else if let ms = Self.number("L_ms", in: timing), ms > 0 {
            // (L: from a game pair's hand-over to the end of its GPU work, the smart gate's own measure, src/xrizer_xros_host.m)
            s.gpuGameMs = Float(ms)
        }
        let c = cpu()
        s.cpuCores = c.cores; s.cpuTop = c.top; s.cpuTopName = c.name
        let m = memory()
        s.memUsedMB = m.used; s.memLeftMB = m.left
        s.thermal = ProcessInfo.processInfo.thermalState.rawValue
        let settings = VXSettings.shared
        let scale = settings.renderScale
        // the picture the game is asked for is a share of the display's own texture (VXImmersive: vx_xros_fixture_offer)
        s.outW = drawable.w; s.outH = drawable.h
        s.eyeW = Int((Double(drawable.w) * scale).rounded()); s.eyeH = Int((Double(drawable.h) * scale).rounded())
        s.upscale = settings.upscale == .metalfx ? (scale < 0.999 ? 2 : 1) : 0
        if s.upscale == 1 { s.upscaleNote = "nothing to upscale at 100 %" }
        s.path = "D3D11 on Metal · OpenVR"
        note(s)
    }
}
#endif
