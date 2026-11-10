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
import simd

struct VXSenseTune {
    private static let env = ProcessInfo.processInfo.environment
    static let predictMaxSeconds: Double = {
        guard let v = env["VXRT_SENSE_PREDICT_MS"], let f = Double(v), f.isFinite else { return 0.05 }
        return max(0, f) / 1000
    }()
    static let pitchDegrees: Float = env["VXRT_SENSE_PITCH_DEG"].flatMap { Float($0) } ?? -31.963   // Klepton: PSVR2 tilt 5.037 + hilt pitch -37
    static let position: SIMD3<Float> = {
        guard let text = env["VXRT_SENSE_POS"] else { return SIMD3(-0.005, 0.02, -0.02) }   // Klepton's general offset
        let parts = text.split(separator: ",").compactMap { Float($0) }
        return parts.count == 3 ? SIMD3(parts[0], parts[1], parts[2]) : .zero
    }()
    static let dropMeters: Float = {
        guard let v = env["VXRT_SENSE_DROP_M"], let f = Float(v), f.isFinite else { return 0 }
        return f
    }()
    static let mirrorLeftX = env["VXRT_SENSE_MIRROR"] != "0"
    static var isIdentity: Bool { pitchDegrees == 0 && position == .zero }

    // The prediction target: the frame's presentation time, no further than `predictMaxSeconds` ahead of now.
    static func predictionTarget(presentation: TimeInterval, now: TimeInterval) -> TimeInterval {
        min(presentation, now + predictMaxSeconds)
    }

    // `origin_from_grip` with the correction applied in the grip's own frame, as x y z qx qy qz qw.
    static func correctedGrip(_ m: simd_float4x4, hand: Int) -> (Float, Float, Float, Float, Float, Float, Float) {
        let raw = simd_normalize(simd_quatf(m)), p = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var position = p, q = raw
        if !isIdentity {
            q = simd_normalize(raw * simd_quatf(angle: pitchDegrees * .pi / 180, axis: SIMD3(1, 0, 0)))
            let offset = (mirrorLeftX && hand == 0) ? SIMD3<Float>(-Self.position.x, Self.position.y, Self.position.z) : Self.position
            position = p + raw.act(offset)
        }
        return (position.x, position.y, position.z, q.vector.x, q.vector.y, q.vector.z, q.vector.w)
    }
}
