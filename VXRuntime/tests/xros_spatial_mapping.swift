import Foundation
import simd
@main struct MappingTest {
    static func main() {
        let id = UUID()
        let a = VXSpatialButton(value: 1, pressed: true, touched: nil)
        let trigger = VXSpatialButton(value: 0.4, pressed: false, touched: true)
        let raw = VXSpatialRawControls(a: a, b: nil, grip: nil, trigger: trigger, stickPress: nil, menu: nil, stick: VXSpatialStick(x: -0.5, y: 0.8))
        func map(_ hand: Int, _ connected: Bool, _ tracking: VXSpatialTracking, _ grip: Bool, _ aim: Bool, _ raw: VXSpatialRawControls) -> VXSpatialCanonicalSnapshot? {
            vxSpatialCanonical(id: id, generation: 12, hand: hand, connected: connected, anchorTime: 10, predictionTime: 10.1,
                inputEventTimeOpaque: 900, captureBeforeTicks: 100, captureAfterTicks: 102,
                tracking: tracking, originFromGrip: grip ? matrix_identity_float4x4 : nil,
                originFromAim: aim ? matrix_identity_float4x4 : nil, raw: raw)
        }
        for hand in 0...1 {
            let out = map(hand,true,.positionOrientation,true,false,raw)!
            assert(out.hand == hand && out.generation == 12 && out.controls.primary?.pressed == true)
            assert(out.controls.secondary == nil && out.controls.grip == nil)
            assert(out.controls.trigger?.value == 0.4 && out.controls.trigger?.touched == true)
            assert(out.controls.stick?.x == -0.5 && out.inputEventTimeOpaque == 900)
            assert(out.gripPose.orientationValid && out.gripPose.positionTracked && !out.aimPose.orientationValid)
        }
        assert(map(0,false,.positionOrientation,true,true,raw) == nil)
        let orientation = map(1,true,.orientation,true,true,raw)!
        assert(orientation.gripPose.orientationTracked && !orientation.gripPose.positionValid)
        let low = map(0,true,.positionOrientationLowAccuracy,false,true,raw)!
        assert(!low.gripPose.orientationValid && low.aimPose.positionValid && !low.aimPose.positionTracked)
        var invalid = raw; invalid.trigger = VXSpatialButton(value: .nan, pressed: true, touched: nil); invalid.stick = VXSpatialStick(x: 2, y: 0)
        let clean = map(0,true,.positionOrientation,true,true,invalid)!
        assert(clean.controls.trigger?.value == nil && clean.controls.trigger?.pressed == true && clean.controls.stick?.x == nil && clean.controls.stick?.y == 0)
        assert(vxSpatialCanonical(id: id, generation: 0, hand: 0, connected: true, anchorTime: 10, predictionTime: 10,
            inputEventTimeOpaque: 1, captureBeforeTicks: 10, captureAfterTicks: 11, tracking: .orientation,
            originFromGrip: nil, originFromAim: nil, raw: raw) == nil)
        assert(vxSpatialCanonical(id: id, generation: 1, hand: 0, connected: true, anchorTime: 10, predictionTime: 10,
            inputEventTimeOpaque: 1, captureBeforeTicks: 12, captureAfterTicks: 11, tracking: .orientation,
            originFromGrip: nil, originFromAim: nil, raw: raw) == nil)
        var badMatrix = matrix_identity_float4x4; badMatrix[0][0] = .nan
        let rejected = vxSpatialCanonical(id: id, generation: 1, hand: 0, connected: true, anchorTime: 10, predictionTime: 10,
            inputEventTimeOpaque: 1, captureBeforeTicks: 10, captureAfterTicks: 11, tracking: .positionOrientation,
            originFromGrip: badMatrix, originFromAim: matrix_identity_float4x4, raw: raw)!
        assert(rejected.originFromGrip == nil && !rejected.gripPose.orientationValid && rejected.aimPose.positionValid)
        print("Spatial canonical input mapping: pass; injected aliases, no physical-device claim")
    }
}
