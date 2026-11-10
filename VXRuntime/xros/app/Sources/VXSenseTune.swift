// Sense grip-pose correction, adapted from Klepton's KleptonControllers.swift (struct KLSenseTune and sensePose()).
// Klepton is MIT, Copyright (c) 2026 Max Thomas; upstream https://github.com/shinyquagsire23/Klepton at
// 1fe7e6caf6bb8bc90c1a5e61d5b9bfc6e110fa32, visionos/Sources/KleptonControllers.swift lines 258-415 (the tuning
// struct) and 680-755 (rotate the grip about its own frame, move it in that frame, mirror the shared X offset for the
// left hand, cap the prediction horizon). The AVP Play fork (toolchain 866-e65c433, no full git pin) has the same
// code in this area; upstream was used. The full MIT notice is third_party/klepton_openxr/LICENSE.
//
// What differs, deliberately: Klepton's defaults (5.037 deg ALVR tilt, -37 deg hilt pitch measured in Beat Saber, a
// (-0.005, 0.02, -0.02) m offset) are for the OVR/Unity guest it targets and are NOT applied here. Our consumer is
// xrizer's Oculus Touch mapping for Skyrim VR, for which no Sense grip offset has been measured, so the default is the
// platform's own `.grip` unchanged. The levers remain, in the grip's frame:
//   VXRT_SENSE_PITCH_DEG=<deg about X>   VXRT_SENSE_POS="x,y,z" (m; X mirrored for the left hand unless
//   VXRT_SENSE_MIRROR=0)   VXRT_SENSE_PREDICT_MS=<ms> (default 50, 0 = no prediction beyond now).
import Foundation
import QuartzCore
import simd

struct VXSenseTune {
    private static let env = ProcessInfo.processInfo.environment
    static let predictMaxSeconds: Double = {
        guard let v = env["VXRT_SENSE_PREDICT_MS"], let f = Double(v), f.isFinite else { return 0.05 }
        return max(0, f) / 1000
    }()
    // Device run 14 (the user): with Klepton's -31.963 the controller Skyrim draws is pitched about 30 degrees forward/down against the hand while the
    // position is right. That value is Klepton's tune for an OVR guest (Beat Saber's own controller adjustment on top of Apple's grip); xrizer
    // already turns the OpenXR grip into the OpenVR device pose with the Touch profile's own 20.6 degree offset
    // (oculus_touch.rs offset_grip_pose), so the Sense grip is passed on unrotated by default. VXRT_SENSE_PITCH_DEG=-31.963 restores Klepton's.
    static let envPitch: Float = env["VXRT_SENSE_PITCH_DEG"].flatMap { Float($0) } ?? 0
    // Which ARKit frame the pose given to the game is built from. Device run 14 (the user, with the compositor's own markers): the model sat where the
    // ARKit AIM frame is, not where the grip-derived pose put it (the aim, 7.8 cm ahead of the grip along its -Z and pitched -34.8 deg, is where the
    // Sense controller's body is; xrizer's Touch profile then moves the game's device pose another 9.6 cm forward from whatever grip it is handed).
    // So by default the "grip" handed to xrizer is aim * inverse(Touch grip->tracked offset): xrizer's own offset then lands the model's origin exactly on
    // the ARKit aim frame, position and orientation. VXRT_SENSE_BASE=grip restores the grip-derived pose (with Klepton's offset below).
    static let useAim = env["VXRT_SENSE_BASE"] != "grip"
    // xrizer's Oculus Touch profile: the OpenVR device pose = OpenXR grip * inverse(R(20.6 deg about X) T(+-0.007, -0.00182941, 0.1019482))
    // (third_party/xrizer/upstream/src/input/profiles/oculus_touch.rs offset_grip_pose; left hand +0.007).
    static func touchTracked(_ hand: Int) -> simd_float4x4 {
        let r = simd_float4x4(simd_quatf(angle: -20.6 * .pi / 180, axis: SIMD3(1, 0, 0)))
        let t = SIMD3<Float>(hand == 0 ? 0.007 : -0.007, -0.00182941, 0.1019482)
        var m = r; let p = -(r * SIMD4(t, 0)); m.columns.3 = SIMD4(p.x, p.y, p.z, 1); return m
    }
    static let envPosition: SIMD3<Float> = {
        guard let text = env["VXRT_SENSE_POS"] else { return useAim ? .zero : SIMD3(-0.005, 0.02, -0.02) }   // Klepton's general offset, grip base only
        let parts = text.split(separator: ",").compactMap { Float($0) }
        return parts.count == 3 ? SIMD3(parts[0], parts[1], parts[2]) : .zero
    }()
    // Live tuning for a session on the headset: Documents/vxrt_sense.txt, re-read once a second, words "pitch=<deg> yaw=<deg> roll=<deg>
    // pos=x,y,z" (degrees about the grip's X, Y, Z in that order; metres in the grip frame). Copy a new file in with devicectl while the app runs.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live = (pitch: envPitch, yaw: Float(0), roll: Float(0), pos: envPosition)
    nonisolated(unsafe) private static var liveChecked = 0.0
    nonisolated(unsafe) private static var liveStamp = Date.distantPast
    static var pitchDegrees: Float { refresh(); return live.pitch }
    static var position: SIMD3<Float> { refresh(); return live.pos }
    private static func refresh() {
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        guard now - liveChecked >= 1 else { return }
        liveChecked = now
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/vxrt_sense.txt")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path), let stamp = attrs[.modificationDate] as? Date, stamp != liveStamp,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        liveStamp = stamp
        var t = (pitch: envPitch, yaw: Float(0), roll: Float(0), pos: envPosition)
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == ";" }) {
            let kv = word.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "pitch": if let v = Float(kv[1]) { t.pitch = v }
            case "yaw": if let v = Float(kv[1]) { t.yaw = v }
            case "roll": if let v = Float(kv[1]) { t.roll = v }
            case "pos": let p = kv[1].split(separator: ",").compactMap { Float($0) }; if p.count == 3 { t.pos = SIMD3(p[0], p[1], p[2]) }
            default: break
            }
        }
        live = t
        vxrt_jlog("sense_tune", "\"pitch\":\(t.pitch),\"yaw\":\(t.yaw),\"roll\":\(t.roll),\"pos\":[\(t.pos.x),\(t.pos.y),\(t.pos.z)]")
    }
    static var yawDegrees: Float { refresh(); return live.yaw }
    static var rollDegrees: Float { refresh(); return live.roll }
    static let dropMeters: Float = {
        guard let v = env["VXRT_SENSE_DROP_M"], let f = Float(v), f.isFinite else { return 0 }
        return f
    }()
    static let mirrorLeftX = env["VXRT_SENSE_MIRROR"] != "0"
    static var isIdentity: Bool { pitchDegrees == 0 && yawDegrees == 0 && rollDegrees == 0 && position == .zero }

    // The prediction target: the frame's presentation time, no further than `predictMaxSeconds` ahead of now.
    static func predictionTarget(presentation: TimeInterval, now: TimeInterval) -> TimeInterval {
        min(presentation, now + predictMaxSeconds)
    }

    // `origin_from_grip` with the correction applied in the grip's own frame, as x y z qx qy qz qw.
    // The pose handed to xrizer as the controller's grip: see `useAim`.
    static func gripForGame(grip: simd_float4x4, aim: simd_float4x4, hand: Int) -> (Float, Float, Float, Float, Float, Float, Float) {
        correctedGrip(useAim ? aim * touchTracked(hand).inverse : grip, hand: hand)
    }
    static func rawPose(_ m: simd_float4x4) -> (Float, Float, Float, Float, Float, Float, Float) {
        let q = simd_normalize(simd_quatf(m)), p = m.columns.3
        return (p.x, p.y, p.z, q.vector.x, q.vector.y, q.vector.z, q.vector.w)
    }
    static func correctedGrip(_ m: simd_float4x4, hand: Int) -> (Float, Float, Float, Float, Float, Float, Float) {
        let raw = simd_normalize(simd_quatf(m)), p = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var position = p, q = raw
        if !isIdentity {
            let d = Float.pi / 180
            q = simd_normalize(raw * simd_quatf(angle: pitchDegrees * d, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: yawDegrees * d, axis: SIMD3(0, 1, 0))
                               * simd_quatf(angle: rollDegrees * d, axis: SIMD3(0, 0, 1)))
            let offset = (mirrorLeftX && hand == 0) ? SIMD3<Float>(-Self.position.x, Self.position.y, Self.position.z) : Self.position
            position = p + raw.act(offset)
        }
        return (position.x, position.y, position.z, q.vector.x, q.vector.y, q.vector.z, q.vector.w)
    }
}
