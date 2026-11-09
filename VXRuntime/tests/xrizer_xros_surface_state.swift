@main struct FixtureSurfaceControl {
    static func main() {
        var state = VXFixtureSurfaceState()
        precondition(!state.paused())             // Initial pause does not discard startup.
        precondition(state.started())             // First actual drawable activates it.
        precondition(state.paused())              // Active pause stops exactly once.
        precondition(!state.started())            // No restart after surface loss.
        precondition(!state.paused() && !state.invalidated())
        var invalidated = VXFixtureSurfaceState()
        precondition(invalidated.invalidated())   // Early invalidation unblocks readiness.
        precondition(!invalidated.started())
        print("fixture surface transitions: pass; CPU control, no simulator or headset")
    }
}
