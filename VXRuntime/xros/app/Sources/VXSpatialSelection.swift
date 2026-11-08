// Pure selection used by the Apple spatial snapshot collector. Ambiguous hand
// identities are withheld; an old generation cannot survive a reconnect.
import Foundation

final class VXTrackingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    func pause() { lock.lock(); paused = true; lock.unlock() }
    func resume() { lock.lock(); paused = false; lock.unlock() }
    func read<T>(_ body: () -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !paused else { return nil }
        return body()
    }
}

struct VXSpatialCandidate {
    let id: UUID
    let hand: Int
    let generation: UInt64
    let live: Bool
}

// Conservative diagnostic freshness envelope; real device validation must
// establish the appropriate limit before these observations drive a game.
func vxSpatialTimeValid(_ sample: Double, presentation: Double) -> Bool {
    sample.isFinite && presentation.isFinite && sample > 0 && presentation > 0 &&
        sample <= presentation + 0.05 && presentation - sample <= 0.25
}

func vxSpatialUnambiguousIndices(_ candidates: [VXSpatialCandidate], generation: UInt64) -> [Int] {
    let eligible = candidates.indices.filter { i in
        let c = candidates[i]
        return c.live && c.generation == generation && (c.hand == 0 || c.hand == 1)
    }
    return eligible.filter { i in
        let c = candidates[i]
        return eligible.filter { candidates[$0].hand == c.hand }.count == 1 &&
               eligible.filter { candidates[$0].id == c.id }.count == 1
    }
}
