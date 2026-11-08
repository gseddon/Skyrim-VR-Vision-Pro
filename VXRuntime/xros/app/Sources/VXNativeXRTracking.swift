// Local spatial-controller observations for the future native provider host.
// These observations are not yet registered with Klepton's disconnected-only v1 input host.
import ARKit
import GameController
import Foundation
import Darwin
import simd

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
    private var accessoryProvider: AccessoryTrackingProvider?
    private var generation: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var devices: [ObjectIdentifier: GCController] = [:]
    private var refreshing = false
    private var refreshAgain = false
    private var stopped = false
    private var latest: [VXSpatialObservation] = []

    init(session: ARKitSession, world: WorldTrackingProvider, hands: HandTrackingProvider?, gate: VXTrackingGate) {
        self.session = session; self.world = world; self.hands = hands; self.gate = gate
    }

    func start() async {
        guard !stopped, AccessoryTrackingProvider.isSupported else { return }
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.refresh() }
            }
            observers.append(token)
        }
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
            var providers: [any DataProvider] = [world]
            if let hands { providers.append(hands) }
            let next = loaded.isEmpty ? nil : AccessoryTrackingProvider(accessories: loaded)
            if let next { providers.append(next) }
            gate.pause()
            do {
                try await session.run(providers)
                if !stopped && pass == generation { devices = current; accessoryProvider = next }
                else { refreshAgain = true }
            } catch { /* provider unavailable: leave every observation invalid */ }
            gate.resume()
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
                inputEventTime: input.lastEventTimestamp, canonical: canonical))
        }
        let candidates = output.map { observation in
            VXSpatialCandidate(id: observation.accessoryID, hand: observation.chirality == .left ? 0 : 1,
                               generation: observation.connectionGeneration, live: true)
        }
        return vxSpatialUnambiguousIndices(candidates, generation: generation).map { output[$0] }
    }

    func collect(at presentation: TimeInterval) {
        latest = snapshot(at: presentation)
    }
}
