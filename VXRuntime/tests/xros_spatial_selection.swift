import Foundation
@main struct SelectionTest {
    static func main() {
        let a = UUID(), b = UUID(), c = UUID()
        func item(_ id: UUID, _ hand: Int, _ generation: UInt64, _ live: Bool = true) -> VXSpatialCandidate {
            VXSpatialCandidate(id: id, hand: hand, generation: generation, live: live)
        }
        assert(vxSpatialUnambiguousIndices([item(a,0,3), item(b,1,3)], generation: 3) == [0,1])
        assert(vxSpatialUnambiguousIndices([item(a,0,3), item(b,1,3,false)], generation: 3) == [0])
        assert(vxSpatialUnambiguousIndices([item(a,0,2), item(b,1,3)], generation: 3) == [1])
        assert(vxSpatialUnambiguousIndices([item(a,0,3), item(c,0,3), item(b,1,3)], generation: 3) == [2])
        assert(vxSpatialUnambiguousIndices([item(a,0,3), item(a,1,3)], generation: 3).isEmpty)
        assert(vxSpatialTimeValid(10, presentation: 10.1))
        assert(!vxSpatialTimeValid(9, presentation: 10))
        assert(!vxSpatialTimeValid(11, presentation: 10))
        assert(!vxSpatialTimeValid(.nan, presentation: 10))
        let gate = VXTrackingGate()
        var reads = 0
        assert(gate.read { reads += 1; return reads } == 1)
        gate.pause()
        assert(gate.read { reads += 1; return reads } == nil && reads == 1)
        gate.resume()
        assert(gate.read { reads += 1; return reads } == 2)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let paused = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = gate.read { entered.signal(); release.wait(); return 1 }
            finished.signal()
        }
        assert(entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async { gate.pause(); paused.signal() }
        assert(paused.wait(timeout: .now() + 0.05) == .timedOut)
        release.signal()
        assert(finished.wait(timeout: .now() + 2) == .success)
        assert(paused.wait(timeout: .now() + 2) == .success)
        assert(gate.read { 3 } == nil)
        gate.resume()
        print("Spatial snapshot selection: pass; injected identities only")
    }
}
