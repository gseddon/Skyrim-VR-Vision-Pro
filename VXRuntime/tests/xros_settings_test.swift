// Mac test of the app's settings store and its mapping to the VXRT_* environment (xros/app/Sources/VXSettings.swift).
// Built with that file only: swiftc -o build/xros_settings_test xros/app/Sources/VXSettings.swift tests/xros_settings_test.swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }
func fresh() -> UserDefaults { let n = "vxrt-settings-test-\(UUID().uuidString)"; let d = UserDefaults(suiteName: n)!; d.removePersistentDomain(forName: n); return d }
func map(_ s: VXSettings) -> [String: String] { Dictionary(uniqueKeysWithValues: s.exports().map { ($0.name, $0.value) }) }

@main enum T {
    static func main() {
        // defaults: 0.7, lower latency (1 in flight), hands hidden, no automatic start, nothing else exported
        var d = fresh()
        var s = VXSettings(defaults: d, info: [:], environment: [:])
        check(s.renderScale == 0.75 && s.latency == .smart && s.upscale == .metalfx && !s.showHands && !s.startAutomatically && s.predictMs == nil && s.stageEyeHeight == nil, "defaults")
        check(map(s) == ["VXRT_RENDER_SCALE": "0.75", "VXRT_UPSCALE": "metalfx", "VXRT_GATE": "smart"], "default exports \(map(s))")

        // persistence under Klepton's keys, read back by a new store
        s.renderScale = 0.85; s.latency = .throughput; s.upscale = .bilinear; s.showHands = true; s.startAutomatically = true; s.predictMs = 40; s.stageEyeHeight = 1.2
        check(d.double(forKey: "klepton.renderScale") == 0.85, "klepton.renderScale stored")
        check(d.data(forKey: "klepton.chroma").flatMap { try? JSONDecoder().decode(VXHandsBlob.self, from: $0) }?.handMatting == true, "klepton.chroma blob stored")
        let s2 = VXSettings(defaults: d, info: [:], environment: [:])
        check(s2.renderScale == 0.85 && s2.latency == .throughput && s2.upscale == .bilinear && s2.showHands && s2.startAutomatically && s2.predictMs == 40 && s2.stageEyeHeight == 1.2, "persisted values read back")
        check(map(s2) == ["VXRT_RENDER_SCALE": "0.85", "VXRT_UPSCALE": "bilinear", "VXRT_GATE": "off", "VXRT_PREDICT_MS": "40", "VXRT_STAGE_EYE_HEIGHT": "1.20"], "exports \(map(s2))")
        s2.predictMs = nil; s2.stageEyeHeight = nil
        check(d.object(forKey: "vxrt.predictMs") == nil && d.object(forKey: "vxrt.stageEyeHeight") == nil, "auto removes the stored value")

        // gameplay: Skyrim's own settings go out as VXRT_INI_SET only when picked; "game default" writes nothing
        d = fresh()
        s = VXSettings(defaults: d, info: [:], environment: [:])
        check(s.turn == .game && s.move == .game && s.snapAngle == nil && s.turnSpeed == nil && map(s)["VXRT_INI_SET"] == nil, "gameplay defaults write nothing")
        s.turn = .snap; s.move = .walk; s.snapAngle = 45
        check(map(s)["VXRT_INI_SET"] == "VRInput.bGamepadLookAngleSnapping=1;VRInput.bGamepadLookAngleSnapSmoothing=0;VRInput.bDirectMovementWithWands=1;VRInput.fGamepadLookAngleSnapAmount=45", "snap/walk ini \(map(s)["VXRT_INI_SET"] ?? "nil")")
        s.turn = .smooth; s.move = .teleport; s.snapAngle = nil; s.turnSpeed = 2.5
        check(map(s)["VXRT_INI_SET"] == "VRInput.bGamepadLookAngleSnapping=0;VRInput.bDirectMovementWithWands=0;VRInput.fGamepadLookAngleSnapSmoothingSpeed=2.50", "smooth/teleport ini \(map(s)["VXRT_INI_SET"] ?? "nil")")
        check(d.string(forKey: "vxrt.turn") == "smooth" && d.string(forKey: "vxrt.move") == "teleport" && d.double(forKey: "vxrt.turnSpeed") == 2.5 && d.object(forKey: "vxrt.snapAngle") == nil, "gameplay stored under vxrt.*")
        let g = VXSettings(defaults: d, info: [:], environment: [:])
        check(g.turn == .smooth && g.move == .teleport && g.turnSpeed == 2.5 && g.snapAngle == nil, "gameplay read back")
        g.turn = .game; g.move = .game; g.turnSpeed = nil
        check(map(g)["VXRT_INI_SET"] == nil && d.object(forKey: "vxrt.turnSpeed") == nil, "back to game default writes nothing")
        // out-of-range values are clamped in the export; plist defaults sit below saved; env beats saved
        s = VXSettings(defaults: fresh(), info: ["VXTurnDefault": "snap", "VXMoveDefault": "walk"], environment: [:])
        check(s.turn == .snap && s.move == .walk, "gameplay plist defaults")
        s = VXSettings(defaults: d, info: [:], environment: ["VXRT_SNAP_ANGLE": "200"])
        check(map(s)["VXRT_INI_SET"] == "VRInput.fGamepadLookAngleSnapAmount=90", "snap angle clamped \(map(s)["VXRT_INI_SET"] ?? "nil")")
        s.turn = .smooth; s.move = .walk
        s = VXSettings(defaults: d, info: ["VXTurnDefault": "snap"], environment: ["VXRT_TURN": "snap", "VXRT_MOVE": "teleport"])
        check(s.turn == .snap && s.move == .teleport, "env beats saved gameplay")
        // a launch's own VXRT_INI_SET goes first (the first match wins in client.c) and is kept
        s = VXSettings(defaults: fresh(), info: [:], environment: ["VXRT_INI_SET": "Display.bUseTAA=0;VRInput.bDirectMovementWithWands=1", "VXRT_MOVE": "teleport"])
        check(map(s)["VXRT_INI_SET"] == "Display.bUseTAA=0;VRInput.bDirectMovementWithWands=1;VRInput.bDirectMovementWithWands=0", "launch ini first \(map(s)["VXRT_INI_SET"] ?? "nil")")
        setenv("VXRT_INI_SET", "Display.bUseTAA=0", 1); unsetenv("VXRT_MOVE")
        s = VXSettings(defaults: fresh(), info: [:], environment: ["VXRT_INI_SET": "Display.bUseTAA=0", "VXRT_MOVE": "walk"])
        _ = s.applyEnvironment()
        check(getenv("VXRT_INI_SET").map { String(cString: $0) } == "Display.bUseTAA=0;VRInput.bDirectMovementWithWands=1", "applyEnvironment merges VXRT_INI_SET")
        for n in ["VXRT_INI_SET", "VXRT_RENDER_SCALE", "VXRT_UPSCALE", "VXRT_GATE"] { unsetenv(n) }

        // clamping and steps
        check(VXSettings.clampScale(0.1) == 0.5 && VXSettings.clampScale(3) == 1.0 && abs(VXSettings.clampScale(0.73) - 0.75) < 1e-9, "clamp")
        d = fresh(); d.set(0.2, forKey: "klepton.renderScale")
        check(VXSettings(defaults: d, info: [:], environment: [:]).renderScale == 0.5, "stored out-of-range value is clamped")

        // Info.plist defaults (AVP Play's presets), below the saved value
        d = fresh()
        let info: [String: Any] = ["KLRenderScaleDefault": "0.9", "KLHandMattingDefault": "1", "KLAutoBootDefault": "1", "VXLatencyDefault": "smoother", "VXUpscaleDefault": "bilinear"]
        s = VXSettings(defaults: d, info: info, environment: [:])
        check(s.renderScale == 0.9 && s.showHands && s.startAutomatically && s.latency == .throughput && s.upscale == .bilinear, "plist defaults")
        check(VXSettings(defaults: d, info: ["KLHandMattingDefault": "0"], environment: [:]).showHands == false, "KLHandMattingDefault 0 hides")
        s.renderScale = 0.6
        check(VXSettings(defaults: d, info: info, environment: [:]).renderScale == 0.6, "saved beats plist")

        // environment beats saved; VXRT_* canonical, KL_* aliases for the mapped user-level settings
        let env: VXEnvironment = ["VXRT_RENDER_SCALE": "0.55", "VXRT_SHOW_HANDS": "0", "VXRT_PAIRS_IN_FLIGHT": "0", "KL_AUTOBOOT": "0"]
        s = VXSettings(defaults: d, info: info, environment: env)
        check(s.renderScale == 0.55 && !s.showHands && s.latency == .throughput && !s.startAutomatically, "env beats saved/plist")
        s = VXSettings(defaults: fresh(), info: [:], environment: ["KL_OVRP_RENDER_SCALE": "0.8", "KL_HAND_MATTING": "1", "KL_AUTOBOOT": "1"])
        check(s.renderScale == 0.8 && s.showHands && s.startAutomatically, "KL_* aliases")
        s = VXSettings(defaults: fresh(), info: [:], environment: ["VXRT_RENDER_SCALE": "0.6", "KL_OVRP_RENDER_SCALE": "0.9"])
        check(s.renderScale == 0.6, "VXRT_* wins over its KL_* alias")

        // a blob written by Klepton (more fields) is understood; a broken one falls back
        d = fresh(); d.set(Data("{\"enabled\":true,\"distMin\":0.4,\"handMatting\":true,\"colorR\":0.1}".utf8), forKey: "klepton.chroma")
        check(VXSettings(defaults: d, info: [:], environment: [:]).showHands, "Klepton-written blob read")
        d.set(Data("nonsense".utf8), forKey: "klepton.chroma")
        check(!VXSettings(defaults: d, info: [:], environment: [:]).showHands, "broken blob falls back to the default")

        // applying: never replaces a variable the launch set
        setenv("VXRT_GATE", "one", 1); unsetenv("VXRT_RENDER_SCALE")
        s = VXSettings(defaults: fresh(), info: [:], environment: [:])
        let r = s.applyEnvironment()
        check(getenv("VXRT_RENDER_SCALE").map { String(cString: $0) } == "0.75" && String(cString: getenv("VXRT_GATE")) == "one", "applyEnvironment keeps launch env")
        check(r.kept == ["VXRT_GATE"], "kept list \(r.kept)")

        // the launch gate
        check(VXLaunchGate.enabled(info: ["VXStartWindow": "1"], environment: [:], defaultLaunch: true), "gate on")
        check(!VXLaunchGate.enabled(info: ["VXStartWindow": "1"], environment: [:], defaultLaunch: false), "explicit -test/-game: no gate")
        check(!VXLaunchGate.enabled(info: ["VXStartWindow": "1"], environment: ["VXRT_START_WINDOW": "0"], defaultLaunch: true), "env off")
        check(!VXLaunchGate.enabled(info: ["VXStartWindow": "0"], environment: [:], defaultLaunch: true), "plist off")

        // the controller-alignment file
        let v = VXSenseValues.parse("pitch=-12.5 yaw=3 roll=0.25 pos=0.01,-0.02,0.03")
        check(v.pitch == -12.5 && v.yaw == 3 && v.roll == 0.25 && v.pos == SIMD3<Float>(0.01, -0.02, 0.03), "sense parse")
        check(VXSenseValues.parse(v.text) == v, "sense round trip \(v.text)")
        let tmp = NSTemporaryDirectory() + "vxrt_sense_test.txt"
        v.save(path: tmp); check(VXSenseValues.load(path: tmp) == v, "sense file"); VXSenseValues.reset(path: tmp)
        check(VXSenseValues.load(path: tmp) == VXSenseValues(), "sense reset")

        print(failures == 0 ? "xros settings: ok" : "xros settings: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
