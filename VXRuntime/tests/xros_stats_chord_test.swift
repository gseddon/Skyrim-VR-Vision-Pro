// Mac test of the two menu buttons' logic for the performance panel (xros/app/Sources/VXStatsPanel.swift, VXMenuChord), which follows
// Klepton's kl_metrics_chord. Built with -D VX_CHORD_TEST, which leaves the panel itself out:
//   swiftc -D VX_CHORD_TEST -parse-as-library -o build/xros_stats_chord_test xros/app/Sources/VXStatsPanel.swift tests/xros_stats_chord_test.swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

// Runs a script of (time, left down, right down) at 100 polls a second; returns what was passed to the game for each button as the
// spans it was down, and when the panel switched.
func run(_ script: [(Double, Bool, Bool)], until end: Double) -> (left: [(Double, Double)], right: [(Double, Double)], switches: [Double]) {
    var chord = VXMenuChord()
    var left: [(Double, Double)] = [], right: [(Double, Double)] = [], switches: [Double] = []
    var downL: Double?, downR: Double?
    var i = 0, l = false, r = false
    var t = 0.0
    while t <= end + 1e-9 {
        while i < script.count && script[i].0 <= t + 1e-9 { l = script[i].1; r = script[i].2; i += 1 }
        let out = chord.poll(left: l, right: r, now: t)
        if out.switched { switches.append(t) }
        if out.passLeft && downL == nil { downL = t }
        if !out.passLeft, let d = downL { left.append((d, t)); downL = nil }
        if out.passRight && downR == nil { downR = t }
        if !out.passRight, let d = downR { right.append((d, t)); downR = nil }
        t += 0.01
    }
    return (left, right, switches)
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.025 }

@main enum T {
    static func main() {
        // a long press of one button reaches the game a quarter of a second late and ends with the button
        var r = run([(0.10, true, false), (0.80, false, false)], until: 1.5)
        check(r.left.count == 1 && near(r.left[0].0, 0.35) && near(r.left[0].1, 0.80) && r.right.isEmpty && r.switches.isEmpty, "long press \(r)")
        // a tap is played afterwards, for a tenth of a second
        r = run([(0.10, false, true), (0.18, false, false)], until: 1.0)
        check(r.right.count == 1 && near(r.right[0].0, 0.18) && near(r.right[0].1, 0.28) && r.left.isEmpty && r.switches.isEmpty, "tap \(r)")
        // both held for a second: the panel switches once, and the game is told nothing, not even after one is let go first
        r = run([(0.10, true, false), (0.20, true, true), (1.60, false, true), (2.40, false, false)], until: 3.0)
        check(r.switches.count == 1 && near(r.switches[0], 1.20) && r.left.isEmpty && r.right.isEmpty, "chord \(r)")
        // held on and on: still one switch
        r = run([(0.0, true, true), (5.0, false, false)], until: 6.0)
        check(r.switches.count == 1, "one switch per hold \(r.switches)")
        // both together for less than a second: nothing switches and nothing is passed
        r = run([(0.10, true, true), (0.60, false, false)], until: 1.5)
        check(r.switches.isEmpty && r.left.isEmpty && r.right.isEmpty, "short chord \(r)")
        // let one go and press it again within the second: that is a gap, not a hold
        r = run([(0.0, true, true), (0.5, true, false), (0.6, true, true), (1.4, false, false)], until: 2.0)
        check(r.switches.isEmpty && r.left.isEmpty && r.right.isEmpty, "gap in the hold \(r)")
        // a second hold after everything was released switches again
        r = run([(0.0, true, true), (1.2, false, false), (2.0, true, true), (3.2, false, false)], until: 4.0)
        check(r.switches.count == 2, "two holds \(r.switches)")
        // the second button coming after the first is already passed on: the first press ends, the chord takes over
        r = run([(0.0, true, false), (0.5, true, true), (1.7, false, false)], until: 2.5)
        check(r.left.count == 1 && near(r.left[0].0, 0.25) && near(r.left[0].1, 0.50) && r.switches.count == 1 && near(r.switches[0], 1.50), "late second button \(r)")

        print(failures == 0 ? "xros stats chord: ok" : "xros stats chord: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
