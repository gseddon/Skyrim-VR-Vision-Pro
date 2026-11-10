// Sense haptic output, adapted from Klepton's KleptonControllers.swift (hapticsEngine(for:), hapticsPlayer(for:),
// drive(), send(), dropHapticsEngine(), releaseHaptics()). Klepton is MIT, Copyright (c) 2026 Max Thomas; upstream
// https://github.com/shinyquagsire23/Klepton at 1fe7e6caf6bb8bc90c1a5e61d5b9bfc6e110fa32,
// visionos/Sources/KleptonControllers.swift lines 1345-1545 (the fork, toolchain 866-e65c433 with no full git pin,
// has the same engine code near line 1685; upstream used). Full MIT notice: third_party/klepton_openxr/LICENSE.
//
// Wired: xrizer's vibration output -> the provider's haptic host (haptic_host.h) -> vx_xros_haptics_apply/stop
// (src/xrizer_xros_controllers.c) -> vxHapticSink -> VXHapticRouter -> this engine -> that hand's GCController.
// Forwarding is tested in the mock and on the simulator (logged, nothing vibrates there). Never run on a Sense
// controller: whether it is FELT is unverified. Frequency is not used (amplitude and duration only, best effort).
import Foundation
import GameController
import CoreHaptics

final class VXSenseHaptics: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [Int: CHHapticEngine] = [:]
    private var players: [Int: CHHapticAdvancedPatternPlayer] = [:]
    private var running = [false, false]

    // Amplitude 0...1 for a hand's controller (0 silences it). False when that hand has no haptic engine.
    @discardableResult
    func set(hand: Int, amplitude: Float, controller: GCController?) -> Bool {
        guard (0..<2).contains(hand), amplitude.isFinite else { return false }
        let level = min(max(amplitude, 0), 1)
        if level <= 0 {
            lock.lock(); let player = players[hand], was = running[hand]; running[hand] = false; lock.unlock()
            if was { try? player?.pause(atTime: CHHapticTimeImmediate) }
            return true
        }
        guard let player = player(for: hand, controller: controller) else { return false }
        lock.lock(); let started = running[hand]; lock.unlock()
        do {
            if !started { try player.start(atTime: CHHapticTimeImmediate); lock.lock(); running[hand] = true; lock.unlock() }
            try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level, relativeTime: 0)],
                                      atTime: CHHapticTimeImmediate)
            return true
        } catch {
            NSLog("[haptics] hand \(hand): \(error); dropping the engine")
            drop(hand)
            return false
        }
    }

    private func player(for hand: Int, controller: GCController?) -> CHHapticAdvancedPatternPlayer? {
        lock.lock(); let existing = players[hand]; lock.unlock()
        if let existing { return existing }
        guard let engine = engine(for: hand, controller: controller) else { return nil }
        do {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)], relativeTime: 0, duration: 1.0)
            let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            player.loopEnabled = true
            lock.lock(); players[hand] = player; lock.unlock()
            return player
        } catch { NSLog("[haptics] hand \(hand): no continuous player (\(error))"); return nil }
    }

    private func engine(for hand: Int, controller: GCController?) -> CHHapticEngine? {
        lock.lock(); let existing = engines[hand]; lock.unlock()
        if let existing { return existing }
        guard let controller, let haptics = controller.haptics else { NSLog("[haptics] hand \(hand): controller reports no haptics"); return nil }
        // One Sense controller is the whole hand, so the device default is the locality (Klepton's order).
        var made = haptics.createEngine(withLocality: .default)
        if made == nil { made = haptics.createEngine(withLocality: .all) }
        if made == nil, let any = haptics.supportedLocalities.first { made = haptics.createEngine(withLocality: any) }
        guard let engine = made else { NSLog("[haptics] hand \(hand): no engine, localities \(haptics.supportedLocalities)"); return nil }
        engine.stoppedHandler = { [weak self] _ in self?.drop(hand) }
        engine.resetHandler = { [weak self, weak engine] in do { try engine?.start() } catch { self?.drop(hand) } }
        do { try engine.start() } catch { NSLog("[haptics] hand \(hand): engine would not start: \(error)"); return nil }
        lock.lock(); engines[hand] = engine; lock.unlock()
        return engine
    }

    private func drop(_ hand: Int) {
        lock.lock(); let engine = engines.removeValue(forKey: hand); players.removeValue(forKey: hand); running[hand] = false; lock.unlock()
        engine?.stop()
    }

    func release() {
        lock.lock(); let all = engines; engines.removeAll(); players.removeAll(); running = [false, false]; lock.unlock()
        for (_, e) in all { e.stop() }
    }
}

// Which GCController drives which hand (set from the tracking snapshot), and the pulse timing: a request holds the
// amplitude for its duration, then silences it unless a newer request or a stop came first.
final class VXHapticRouter: @unchecked Sendable {
    static let shared = VXHapticRouter()
    private let lock = NSLock()
    private let engine = VXSenseHaptics()
    private var controllers: [Int: GCController] = [:]
    private var generation = [UInt64](repeating: 0, count: 2)

    func setControllers(_ map: [Int: GCController]) {
        lock.lock(); let gone = controllers.keys.filter { map[$0] == nil }; controllers = map; lock.unlock()
        for hand in gone { engine.set(hand: hand, amplitude: 0, controller: nil) }
    }

    func handle(hand: Int, amplitude: Float, seconds: Double, stop: Bool) {
        guard (0..<2).contains(hand) else { return }
        lock.lock(); generation[hand] &+= 1; let mine = generation[hand], controller = controllers[hand]; lock.unlock()
        guard let controller else { NSLog("[haptics] hand \(hand): no tracked Sense controller, request dropped"); return }
        if stop || amplitude <= 0 { engine.set(hand: hand, amplitude: 0, controller: controller); return }
        if !engine.set(hand: hand, amplitude: amplitude, controller: controller) { return }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + max(seconds, 0.005)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.generation[hand] == mine, c = self.controllers[hand]; self.lock.unlock()
            if current { self.engine.set(hand: hand, amplitude: 0, controller: c) }
        }
    }
}

// The C haptic sink (xrizer_xros_controllers.h).
func vxHapticSink(_ hand: Int32, _ amplitude: Float, _ seconds: Double, _ frequency: Float, _ stop: Int32) {
    VXHapticRouter.shared.handle(hand: Int(hand), amplitude: amplitude, seconds: seconds, stop: stop != 0)
}
