/* One-way lifecycle for the explicitly opted-in simulator fixture. */
struct VXFixtureSurfaceState {
    private enum State { case waiting, active, lost }
    private var state: State = .waiting
    mutating func started() -> Bool {
        guard state == .waiting else { return false }
        state = .active
        return true
    }
    mutating func paused() -> Bool {
        guard state == .active else { return false }
        state = .lost
        return true
    }
    mutating func invalidated() -> Bool {
        guard state != .lost else { return false }
        state = .lost
        return true
    }
}
