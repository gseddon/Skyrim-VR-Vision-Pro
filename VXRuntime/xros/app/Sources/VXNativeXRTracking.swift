// Local spatial-controller observations for the native provider host. With XRIZER_XROS_FIXTURE (the simulator
// fixture/game build, where the provider host exists) collect(at:) publishes them to input host version 3 through
// vx_xros_controllers_publish; otherwise they stay local.
import ARKit
import GameController
import Foundation
import Darwin
import QuartzCore
import simd

// Latest published grip/aim positions (provider LOCAL = the accessory session's ARKit origin), for the compositor's pose audit.
final class VXPoseAudit: @unchecked Sendable {
    static let shared = VXPoseAudit()
    private let lock = NSLock()
    private var grip = [SIMD3<Float>?](repeating: nil, count: 2), aim = [SIMD3<Float>?](repeating: nil, count: 2)
    func set(hand: Int, grip g: SIMD3<Float>?, aim a: SIMD3<Float>?) { lock.lock(); grip[hand] = g; aim[hand] = a; lock.unlock() }
    func get() -> (grip: [SIMD3<Float>?], aim: [SIMD3<Float>?]) { lock.lock(); defer { lock.unlock() }; return (grip, aim) }
}

func vxSpatialSide(_ chirality: Accessory.Chirality) -> VXSpatialSide {
    switch chirality {
    case .left: return .left
    case .right: return .right
    case .unspecified: return .unspecified
    @unknown default: return .unspecified
    }
}

struct VXSpatialObservation {
    let connectionGeneration: UInt64
    let accessoryID: UUID
    let chirality: Accessory.Chirality
    let anchorTime: TimeInterval
    let predictedTime: TimeInterval
    let trackingState: AccessoryAnchor.TrackingState
    let originFromGrip: simd_float4x4?
    let originFromAim: simd_float4x4?
    // Bracketed Mach ticks identify capture time; GC's event timestamp has an
    // unspecified epoch and is retained only as an opaque ordering value.
    let inputCaptureBefore: UInt64
    let inputCaptureAfter: UInt64
    let inputEventTime: TimeInterval
    let canonical: VXSpatialCanonicalSnapshot
    let controller: GCController
}

// ARKit's world query is documented not thread safe. Reconfiguring the shared
// session suspends queries until run() finishes; the renderer reports missing
// tracking during that interval instead of using an old pose.

// One ARKitSession is shared with the compositor's world/hand providers. Actor
// isolation serializes collection; no controller or pose is invented on failure.
actor VXNativeXRTracking {
    private let session: ARKitSession
    private let world: WorldTrackingProvider
    private let hands: HandTrackingProvider?
    private let gate: VXTrackingGate
    // true: this adapter's ARKitSession carries ONLY the Sense accessories (the head runs in its own session), so a slow or
    // blocked accessory run can never take the head pose away (device run 4: the combined run never returned; no head, no frames).
    private let accessoryOnly: Bool
    private var accessoryProvider: AccessoryTrackingProvider?
    private var generation: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var devices: [ObjectIdentifier: GCController] = [:]
    private var refreshing = false
    private var refreshAgain = false
    private var stopped = false
    private var lastLogged: (connected: Int, loaded: Int)?
    private var latest: [VXSpatialObservation] = []

    init(session: ARKitSession, world: WorldTrackingProvider, hands: HandTrackingProvider?, gate: VXTrackingGate, accessoryOnly: Bool = false) {
        self.session = session; self.world = world; self.hands = hands; self.gate = gate; self.accessoryOnly = accessoryOnly
    }

    func start() async {
        guard !stopped else { return }
        guard AccessoryTrackingProvider.isSupported else {
            vxrt_jlog("xr_controllers", "\"what\":\"AccessoryTrackingProvider unsupported on this device: hands stay disconnected\"")
            await refresh()   // (still the one ARKit run, for the head)
            return
        }
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let controller = note.object as? GCController
                vxrt_jlog("xr_controllers", "\"what\":\"\(name.rawValue == NSNotification.Name.GCControllerDidConnect.rawValue ? "controller connected" : "controller disconnected")\",\"category\":\"\(controller?.productCategory ?? "?")\",\"name\":\"\(controller?.vendorName ?? "?")\",\"re_run\":\"queued\"")
                Task { await self?.refresh() }
            }
            observers.append(token)
        }
#if XRIZER_XROS_FIXTURE
        vx_xros_haptics_set_sink(vxHapticSink)
#endif
        await refresh()
    }

    // Re-run the same session with all existing providers. A connect or
    // disconnect invalidates observations immediately; concurrent notifications
    // are coalesced, and a new pass follows an in-flight async reconfiguration.
    func refresh() async {
        guard !stopped else { return }
        generation &+= 1
        accessoryProvider = nil
        devices = [:]
        latest = []
        if refreshing { refreshAgain = true; return }
        refreshing = true
        repeat {
            refreshAgain = false
            let pass = generation
            let connected = GCController.controllers().filter { $0.productCategory == GCProductCategorySpatialController }
            var loaded: [Accessory] = []
            var current: [ObjectIdentifier: GCController] = [:]
            for controller in connected {
                do { loaded.append(try await Accessory(device: controller)); current[ObjectIdentifier(controller)] = controller }
                catch { /* a failed load leaves that controller unavailable */ }
            }
            if stopped { break }
            if pass != generation { refreshAgain = true; continue }
            // One line per change of the paired set (not per notification): with no Sense controller paired the app
            // carries on, both hands stay disconnected, and a controller that connects later is picked up here.
            if lastLogged?.connected != connected.count || lastLogged?.loaded != loaded.count {
                lastLogged = (connected.count, loaded.count)
                if connected.isEmpty {
                    vxrt_jlog("xr_controllers", "\"what\":\"no spatial controller connected: both hands stay disconnected until one pairs\",\"connected\":0,\"loaded\":0")
                } else {
                    vxrt_jlog("xr_controllers", "\"what\":\"spatial controllers\",\"connected\":\(connected.count),\"loaded\":\(loaded.count),\"names\":\"\(loaded.map { $0.name }.joined(separator: "|"))\"")
                }
            }
            var providers: [any DataProvider] = accessoryOnly ? [] : [world]
            if let hands, !accessoryOnly { providers.append(hands) }
            let next = loaded.isEmpty ? nil : AccessoryTrackingProvider(accessories: loaded)
            if let next { providers.append(next) }
            if !accessoryOnly { gate.pause() }
            vxrt_jlog("xr_controllers", "\"what\":\"session run begin\",\"providers\":\(providers.count),\"accessory_only\":\(accessoryOnly),\"loaded\":\(loaded.count),\"mach_s\":\(String(format: "%.3f", CACurrentMediaTime()))")
            do {
                if !providers.isEmpty { try await session.run(providers) }
                if !stopped && pass == generation { devices = current; accessoryProvider = next }
                else { refreshAgain = true }
                vxrt_jlog("xr_controllers", "\"what\":\"session running\",\"accessory_provider\":\(next != nil),\"accessory_state\":\"\(next.map { "\($0.state)" } ?? "none")\",\"loaded\":\(loaded.count),\"mach_s\":\(String(format: "%.3f", CACurrentMediaTime()))")
            } catch {
                /* provider unavailable: leave every observation invalid */
                vxrt_jlog("xr_controllers", "\"what\":\"session run failed: \(error.localizedDescription)\"")
            }
            if !accessoryOnly { gate.resume() }
        } while refreshAgain && !stopped
        refreshing = false
    }

    func stop() {
        stopped = true; generation &+= 1; accessoryProvider = nil; devices = [:]; latest = []
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    // `presentation` is Mach absolute seconds, as required by the ARKit SDK.
    // Caller must establish that its compositor clock was converted explicitly.
    func snapshot(at presentation: TimeInterval) -> [VXSpatialObservation] {
        guard presentation.isFinite, presentation > 0, let provider = accessoryProvider,
              provider.state == .running else { return [] }
        let live = Set(GCController.controllers().map(ObjectIdentifier.init))
        var output: [VXSpatialObservation] = []
        for anchor in provider.latestAnchors {
            guard case let .device(device) = anchor.accessory.source,
                  let controller = device as? GCController,
                  devices[ObjectIdentifier(controller)] != nil,
                  live.contains(ObjectIdentifier(controller)),
                  let predicted = provider.predictAnchor(for: anchor, at: presentation),
                  predicted.accessory.id == anchor.accessory.id,
                  predicted.isTracked, vxSpatialTimeValid(predicted.timestamp, presentation: presentation) else { continue }
            guard let handIndex = vxSpatialHandIndex(held: predicted.heldChirality.map(vxSpatialSide),
                                                      inherent: vxSpatialSide(predicted.accessory.inherentChirality)) else { continue }
            let hand: Accessory.Chirality = handIndex == 0 ? .left : .right
            let locations = predicted.accessory.locations
            func originFrom(_ location: Accessory.LocationName) -> simd_float4x4? {
                guard locations.contains(location) else { return nil }
                let space = predicted.coordinateSpace(for: location, correction: .rendered)
                guard space.ancestorSpace != nil else { return nil }
                let matrix = space.ancestorFromSpaceTransformFloat().matrix
                guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }) else { return nil }
                return matrix
            }
            let grip = originFrom(.grip), aim = originFrom(.aim)
            let before = mach_absolute_time()
            let input = controller.input.capture()
            let after = mach_absolute_time()
            func button(_ name: GCButtonElementName) -> VXSpatialButton? {
                guard let button = input.buttons[name] else { return nil }
                return VXSpatialButton(value: button.pressedInput.value, pressed: button.pressedInput.isPressed,
                    touched: button.touchedInput?.isTouched, analog: button.pressedInput.isAnalog)
            }
            let rawStick = input.dpads[.thumbstick].map { VXSpatialStick(x: $0.xAxis.value, y: $0.yAxis.value) }
            let raw = VXSpatialRawControls(a: button(.a), b: button(.b), grip: button(.grip), trigger: button(.trigger),
                stickPress: button(.thumbstickButton), menu: button(.menu), stick: rawStick)
            let state: VXSpatialTracking
            switch predicted.trackingState {
            case .untracked: state = .unavailable
            case .orientationTracked: state = .orientation
            case .positionOrientationTracked: state = .positionOrientation
            case .positionOrientationTrackedLowAccuracy: state = .positionOrientationLowAccuracy
            @unknown default: state = .unavailable
            }
            guard let canonical = vxSpatialCanonical(id: predicted.accessory.id, generation: generation,
                hand: handIndex, connected: true, anchorTime: predicted.timestamp,
                predictionTime: presentation, inputEventTimeOpaque: input.lastEventTimestamp,
                captureBeforeTicks: before, captureAfterTicks: after, tracking: state,
                originFromGrip: grip, originFromAim: aim, raw: raw) else { continue }
            output.append(VXSpatialObservation(connectionGeneration: generation, accessoryID: predicted.accessory.id, chirality: hand,
                anchorTime: predicted.timestamp, predictedTime: presentation, trackingState: predicted.trackingState,
                originFromGrip: grip, originFromAim: aim, inputCaptureBefore: before, inputCaptureAfter: after,
                inputEventTime: input.lastEventTimestamp, canonical: canonical, controller: controller))
        }
        let candidates = output.map { observation in
            VXSpatialCandidate(id: observation.accessoryID, hand: observation.chirality == .left ? 0 : 1,
                               generation: observation.connectionGeneration, live: true)
        }
        return vxSpatialUnambiguousIndices(candidates, generation: generation).map { output[$0] }
    }

    func collect(at presentation: TimeInterval) {
#if XRIZER_XROS_FIXTURE
        // Prediction horizon capped as in Klepton (see VXSenseTune); the sample is stamped with the instant predicted.
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let now = Double(mach_absolute_time()) * Double(info.numer) / Double(info.denom) / 1e9
        let target = VXSenseTune.predictionTarget(presentation: presentation, now: now)
        latest = snapshot(at: target)
        publish(latest, at: target)
#else
        latest = snapshot(at: presentation)
#endif
    }

#if XRIZER_XROS_FIXTURE
    // One v3 observation: the hands ARKit tracked at `presentation` (Mach seconds, the clock of frame prediction),
    // in the ARKit origin that is the provider's LOCAL space. A hand without a tracked accessory, or without both
    // grip and aim locations, is published disconnected. Tracked bits follow ARKit's position tracking only.
    // Once a second into host_log.jsonl: what the host publishes for each hand (the console shows the same with -console).
    private var lastStateLog = 0.0
    private func logState(_ hands: [vx_xros_controller_hand]) {
        let now = CACurrentMediaTime()
        guard now - lastStateLog >= 1 else { return }
        lastStateLog = now
        func f(_ v: Float) -> String { v.isFinite ? String(format: "%.3f", v) : "null" }
        for (i, h) in hands.enumerated() {
            let g = h.grip
            let pose = h.connected != 0 ? "\"pos\":[\(f(g.0)),\(f(g.1)),\(f(g.2))],\"pos_tracked\":\(h.grip_position_tracked)," : ""
            vxrt_jlog("xr_controller_state", "\"hand\":\"\(i == 0 ? "left" : "right")\",\"connected\":\(h.connected),\(pose)\"trigger\":\(f(h.trigger)),\"stick\":[\(f(h.stick_x)),\(f(h.stick_y))],\"primary\":\(h.primary),\"secondary\":\(h.secondary),\"grip_pressed\":\(h.grip_pressed),\"menu\":\(h.menu),\"stick_pressed\":\(h.stick_pressed)")
        }
    }

    private func publish(_ observations: [VXSpatialObservation], at presentation: TimeInterval) {
        var hands = [vx_xros_controller_hand](repeating: vx_xros_controller_hand(), count: 2)
        for o in observations {
            let c = o.canonical
            guard (0..<2).contains(c.hand), let grip = o.originFromGrip, let aim = o.originFromAim else { continue }
            func value(_ b: VXSpatialButton?) -> Bool { b?.pressed ?? false }
            func pose(_ m: simd_float4x4) -> (Float, Float, Float, Float, Float, Float, Float) {
                let q = simd_normalize(simd_quatf(m)), p = m.columns.3
                return (p.x, p.y, p.z, q.vector.x, q.vector.y, q.vector.z, q.vector.w)
            }
            var h = vx_xros_controller_hand()
            h.connected = 1
            h.grip_position_tracked = c.gripPose.positionTracked ? 1 : 0
            h.aim_position_tracked = c.aimPose.positionTracked ? 1 : 0
            h.grip = VXSenseTune.correctedGrip(grip, hand: c.hand); h.aim = VXSenseTune.correctedGrip(aim, hand: c.hand)
            // Device run 10: Skyrim's rendered controller sat a few centimetres ABOVE the real one (IMG_0029). A world-space drop (VXRT_SENSE_DROP_M, metres,
            // default 0.04) applied to grip and aim in the provider's LOCAL space (ARKit origin, Y up); eyeballed, not measured. Klepton's own offsets are
            // rotation-dependent (a grip-frame offset and a pivot); this is the one-number version until a measurement says otherwise.
            h.grip.1 -= VXSenseTune.dropMeters; h.aim.1 -= VXSenseTune.dropMeters
            h.trigger = c.controls.trigger?.value ?? .nan
            h.stick_x = c.controls.stick?.x ?? .nan; h.stick_y = c.controls.stick?.y ?? .nan
            if h.stick_x.isNaN || h.stick_y.isNaN { h.stick_x = .nan; h.stick_y = .nan }
            h.primary = value(c.controls.primary) ? 1 : 0; h.secondary = value(c.controls.secondary) ? 1 : 0
            h.grip_pressed = value(c.controls.grip) ? 1 : 0; h.menu = value(c.controls.menu) ? 1 : 0
            h.stick_pressed = value(c.controls.stickPress) ? 1 : 0
            hands[c.hand] = h
            VXPoseAudit.shared.set(hand: c.hand, grip: SIMD3(h.grip.0, h.grip.1, h.grip.2), aim: SIMD3(h.aim.0, h.aim.1, h.aim.2))
        }
        for hand in 0..<2 where hands[hand].connected == 0 { VXPoseAudit.shared.set(hand: hand, grip: nil, aim: nil) }
        var drivers: [Int: GCController] = [:]
        for o in observations where (0..<2).contains(o.canonical.hand) { drivers[o.canonical.hand] = o.controller }
        VXHapticRouter.shared.setControllers(drivers)
        logState(hands)
        let ns = presentation * 1e9
        guard ns.isFinite, ns > 0, ns < Double(Int64.max) else { return }
        vx_xros_controllers_publish(hands, Int64(ns))
    }
#endif
}
