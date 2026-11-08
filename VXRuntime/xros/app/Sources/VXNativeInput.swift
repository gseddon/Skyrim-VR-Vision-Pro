// Local headset input only: actual hand anchors and one extended gamepad on the right.
import ARKit
import GameController
import QuartzCore
import simd

struct VXHandInput {
    var sampleTime = 0.0
    var sequence: UInt64 = 0
    var tracked = false
    var originFromHand = matrix_identity_float4x4
    var padConnected = false
    var trigger: Float = 0
    var triggerPressed = false
    var gripPressed = false
    var stickX: Float = 0
    var stickY: Float = 0
    var stickPressed = false
    var buttonA = false
    var menu = false
}

final class VXNativeInput {
    let hands = HandTrackingProvider()
    private var lastLeft: HandAnchor?
    private var lastRight: HandAnchor?
    private var leftTime = 0.0
    private var rightTime = 0.0
    private var serial: UInt64 = 0
    private var leftSequence: UInt64 = 0
    private var rightSequence: UInt64 = 0
    var handTrackingEnabled = false

    // latestAnchors consumes updates; expiration avoids retaining a lost hand forever.
    func snapshot() -> [VXHandInput] {
        var result = [VXHandInput(), VXHandInput()]
        if handTrackingEnabled {
            let now = CACurrentMediaTime()
            let anchors = hands.latestAnchors
            if let left = anchors.leftHand { lastLeft = left; leftTime = now; serial &+= 1; leftSequence = serial }
            if let right = anchors.rightHand { lastRight = right; rightTime = now; serial &+= 1; rightSequence = serial }
            if let left = lastLeft, left.isTracked, now - leftTime < 0.25 {
                result[0].tracked = true
                result[0].sampleTime = leftTime; result[0].sequence = leftSequence
                result[0].originFromHand = left.originFromAnchorTransform
            }
            if let right = lastRight, right.isTracked, now - rightTime < 0.25 {
                result[1].tracked = true
                result[1].sampleTime = rightTime; result[1].sequence = rightSequence
                result[1].originFromHand = right.originFromAnchorTransform
            }
        }
        if let pad = GCController.controllers().compactMap({ $0.extendedGamepad }).first {
            result[1].padConnected = true
            // Button polling is a new input sample; a cached hand pose keeps its receipt time.
            serial &+= 1; result[1].sequence = serial
            if !result[1].tracked { result[1].sampleTime = CACurrentMediaTime() }
            result[1].trigger = pad.rightTrigger.value
            result[1].triggerPressed = pad.rightTrigger.isPressed
            result[1].gripPressed = pad.rightShoulder.isPressed
            result[1].stickX = pad.rightThumbstick.xAxis.value
            result[1].stickY = pad.rightThumbstick.yAxis.value
            result[1].stickPressed = pad.rightThumbstickButton?.isPressed ?? false
            result[1].buttonA = pad.buttonA.isPressed
            result[1].menu = pad.buttonMenu.isPressed
        }
        return result
    }
}

// Legacy OpenVR axis 0 is the stick and axis 1 the trigger. Button identifiers
// follow EVRButtonId; no touch or haptic state is inferred from a gamepad.
extension VXNativeInput {
    func controllers() -> [vx_native_openvr_controller] {
        let inputs = snapshot()
        return inputs.map { input in
            var c = vx_native_openvr_controller()
            c.sample_time = input.sampleTime
            c.sequence = input.sequence
            c.connected = input.tracked || input.padConnected ? 1 : 0
            c.tracking_valid = input.tracked ? 1 : 0
            var transform = input.originFromHand
            withUnsafePointer(to: &transform) { src in
                withUnsafeMutableBytes(of: &c.origin_from_grip) { dst in
                    dst.copyBytes(from: UnsafeRawBufferPointer(start: src, count: 16 * MemoryLayout<Float>.size))
                }
            }
            if input.padConnected {
                if input.menu { c.pressed |= UInt64(1) << 1 }
                if input.gripPressed { c.pressed |= UInt64(1) << 2 }
                if input.buttonA { c.pressed |= UInt64(1) << 7 }
                if input.stickPressed { c.pressed |= UInt64(1) << 32 }
                if input.triggerPressed { c.pressed |= UInt64(1) << 33 }
                withUnsafeMutableBytes(of: &c.axis) { raw in
                    let axis = raw.bindMemory(to: Float.self)
                    axis[0] = input.stickX; axis[1] = input.stickY; axis[2] = input.trigger
                }
            }
            return c
        }
    }
}
