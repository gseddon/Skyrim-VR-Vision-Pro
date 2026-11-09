// Canonical, provider-independent spatial-controller snapshot. This is not an
// OpenXR interaction profile. v1 input stays disconnected; xrizer_xros_sense.c
// retains a hand without setting the v1 connection bits.
import Foundation
import simd

struct VXSpatialButton {
    var value: Float?
    var pressed: Bool?
    var touched: Bool?
    var analog: Bool? = nil
}
struct VXSpatialStick { var x: Float?; var y: Float? }
enum VXSpatialTracking { case unavailable, orientation, positionOrientation, positionOrientationLowAccuracy }
struct VXSpatialRawControls {
    var a: VXSpatialButton?
    var b: VXSpatialButton?
    var grip: VXSpatialButton?
    var trigger: VXSpatialButton?
    var stickPress: VXSpatialButton?
    var menu: VXSpatialButton?
    var stick: VXSpatialStick?
}
struct VXSpatialMappedControls {
    // Apple names spatial-controller .a/.b for each physical hand; primary is
    // left Square/right Cross and secondary left Triangle/right Circle.
    var primary: VXSpatialButton?
    var secondary: VXSpatialButton?
    var grip: VXSpatialButton?
    var trigger: VXSpatialButton?
    var stickPress: VXSpatialButton?
    var menu: VXSpatialButton?
    var stick: VXSpatialStick?
}
struct VXSpatialPoseValidity {
    var orientationValid = false
    var positionValid = false
    var orientationTracked = false
    var positionTracked = false
}
struct VXSpatialCanonicalSnapshot {
    let accessoryID: UUID
    let generation: UInt64
    let hand: Int
    let anchorTime: Double
    let predictionTime: Double
    let inputEventTimeOpaque: Double
    let captureBeforeTicks: UInt64
    let captureAfterTicks: UInt64
    let originFromGrip: simd_float4x4?
    let originFromAim: simd_float4x4?
    let gripPose: VXSpatialPoseValidity
    let aimPose: VXSpatialPoseValidity
    let controls: VXSpatialMappedControls
}
private func vxSpatialButton(_ value: VXSpatialButton?) -> VXSpatialButton? {
    guard var value else { return nil }
    if let v = value.value, !v.isFinite || v < 0 || v > 1 { value.value = nil }
    return value
}
private func vxSpatialPose(_ available: Bool, _ tracking: VXSpatialTracking) -> VXSpatialPoseValidity {
    guard available else { return VXSpatialPoseValidity() }
    switch tracking {
    case .unavailable: return VXSpatialPoseValidity()
    case .orientation: return VXSpatialPoseValidity(orientationValid: true, positionValid: false, orientationTracked: true, positionTracked: false)
    case .positionOrientation: return VXSpatialPoseValidity(orientationValid: true, positionValid: true, orientationTracked: true, positionTracked: true)
    case .positionOrientationLowAccuracy: return VXSpatialPoseValidity(orientationValid: true, positionValid: true, orientationTracked: true, positionTracked: false)
    }
}
private func vxSpatialMatrix(_ matrix: simd_float4x4?) -> simd_float4x4? {
    guard let matrix, (0..<4).allSatisfy({ column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }) else { return nil }
    return matrix
}
func vxSpatialCanonical(id: UUID, generation: UInt64, hand: Int, connected: Bool,
                        anchorTime: Double, predictionTime: Double, inputEventTimeOpaque: Double,
                        captureBeforeTicks: UInt64, captureAfterTicks: UInt64,
                        tracking: VXSpatialTracking, originFromGrip: simd_float4x4?, originFromAim: simd_float4x4?,
                        raw: VXSpatialRawControls) -> VXSpatialCanonicalSnapshot? {
    guard connected, generation != 0, (hand == 0 || hand == 1),
          vxSpatialTimeValid(anchorTime, presentation: predictionTime),
          captureBeforeTicks != 0, captureAfterTicks >= captureBeforeTicks else { return nil }
    var stick = raw.stick
    if let x = stick?.x, !x.isFinite || abs(x) > 1 { stick?.x = nil }
    if let y = stick?.y, !y.isFinite || abs(y) > 1 { stick?.y = nil }
    let grip = vxSpatialMatrix(originFromGrip), aim = vxSpatialMatrix(originFromAim)
    let controls = VXSpatialMappedControls(primary: vxSpatialButton(raw.a), secondary: vxSpatialButton(raw.b),
        grip: vxSpatialButton(raw.grip), trigger: vxSpatialButton(raw.trigger), stickPress: vxSpatialButton(raw.stickPress),
        menu: vxSpatialButton(raw.menu), stick: stick)
    return VXSpatialCanonicalSnapshot(accessoryID: id, generation: generation, hand: hand,
        anchorTime: anchorTime, predictionTime: predictionTime, inputEventTimeOpaque: inputEventTimeOpaque,
        captureBeforeTicks: captureBeforeTicks, captureAfterTicks: captureAfterTicks,
        originFromGrip: grip, originFromAim: aim,
        gripPose: vxSpatialPose(grip != nil, tracking), aimPose: vxSpatialPose(aim != nil, tracking), controls: controls)
}
