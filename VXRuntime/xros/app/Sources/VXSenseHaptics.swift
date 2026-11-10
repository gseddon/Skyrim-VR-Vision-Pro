// Sense haptic output, adapted from Klepton's KleptonControllers.swift (hapticsEngine(for:), hapticsPlayer(for:),
// drive(), send(), dropHapticsEngine(), releaseHaptics()). Klepton is MIT, Copyright (c) 2026 Max Thomas; upstream
// https://github.com/shinyquagsire23/Klepton at 1fe7e6caf6bb8bc90c1a5e61d5b9bfc6e110fa32,
// visionos/Sources/KleptonControllers.swift lines 1345-1545 (the fork, toolchain 866-e65c433 with no full git pin,
// has the same engine code near line 1685; upstream used). Full MIT notice: third_party/klepton_openxr/LICENSE.
//
// NOT WIRED: the native provider (third_party/klepton_openxr/src/core.c) still refuses xrApplyHapticFeedback and has
// no haptic host boundary, so nothing calls set(hand:amplitude:controller:) from xrizer's vibration output yet. This
// is the GameController -> CoreHaptics half only, untested without a controller. Not a claim that haptics work.
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
