// Mac test of the settings window's picture presets (xros/app/Sources/VXPresets.swift) over the settings store (VXSettings.swift):
// the three built-in presets from the standard picture, which preset a picture is, applying one, the player's own presets and their
// shared text, and M2 against M5.
// swiftc -parse-as-library -o build/xros_presets_test xros/app/Sources/VXSettings.swift xros/app/Sources/VXPresets.swift tests/xros_presets_test.swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }
func fresh() -> UserDefaults { let n = "vxrt-presets-test-\(UUID().uuidString)"; let d = UserDefaults(suiteName: n)!; d.removePersistentDomain(forName: n); return d }

@main enum T {
    static func main() {
        let std = VXSettings.standardPicture(info: [:])
        check(std == VXPicture(baseResolution: 0, renderScale: 0.75, upscale: "metalfx", displayQuality: 1.0, plainResample: false,
                               foveatedRendering: "off", edgeMask: "standard"), "standard picture \(std)")

        let perf = VXPresetRules.performance(from: std)
        check(perf.renderScale == 0.75 && perf.upscale == "metalfx", "performance: 75 % with MetalFX")
        check(perf.baseResolution == 0 && perf.foveatedRendering == "medium",
              "performance: at the smallest base, foveated rendering instead (\(perf))")
        var std3072 = std; std3072.baseResolution = 3072
        check(VXPresetRules.performance(from: std3072).baseResolution == 2560 && VXPresetRules.performance(from: std3072).foveatedRendering == "off",
              "performance: one base step lower where there is one")
        var std100 = std; std100.renderScale = 1.0; std100.upscale = "bilinear"
        check(VXPresetRules.performance(from: std100).baseResolution == 0 && VXPresetRules.performance(from: std100).foveatedRendering == "off",
              "performance from 100 %: base and foveation unchanged")

        let q = VXPresetRules.quality(from: std)
        check(q.baseResolution == 2560 && q.edgeMask == "off" && q.displayQuality == 1.0, "quality: next base, whole picture, finest display \(q)")
        check(q.renderScale == std.renderScale && q.foveatedRendering == std.foveatedRendering, "quality: rest as standard")
        check(VXPresetRules.baseStep(4096, by: 1) == 4096 && VXPresetRules.baseStep(0, by: 1) == 2560 && VXPresetRules.baseStep(2048, by: -1) == 2048, "base steps clamp")

        check(VXPresetRules.matching(std, standard: std, custom: []) == .builtIn(.standard), "matches standard")
        check(VXPresetRules.matching(q, standard: std, custom: []) == .builtIn(.quality), "matches quality")
        var mine = std; mine.renderScale = 0.9
        check(VXPresetRules.matching(mine, standard: std, custom: []) == nil, "matches none")

        // applying a preset to a settings store, read back by a new store
        let d = fresh()
        let s = VXSettings(defaults: d, info: [:], environment: [:])
        s.apply(q)
        check(VXSettings(defaults: d, info: [:], environment: [:]).picture == q, "applied preset persists")

        // own presets
        let store = VXPresetStore(defaults: fresh())
        let saved = store.save(name: " Mein M2 ", picture: mine, device: "M2")
        check(store.presets.map(\.name) == ["Mein M2"], "saved")
        check(VXPresetRules.matching(mine, standard: std, custom: store.presets) == .custom(saved.id), "matches own")
        store.save(name: "mein m2", picture: perf, device: "M2")
        check(store.presets.count == 1 && store.presets[0].picture == perf, "same name replaces")
        store.rename(saved.id, to: "Abend")
        check(store.presets[0].name == "Abend", "renamed")
        let text = VXPresetStore.shareText(store.presets[0])
        let back = VXPresetStore.parse("hier:\n" + text)
        check(back?.name == "Abend" && back?.device == "M2" && back?.picture == perf, "shared text read back")
        check(VXPresetStore.parse("nichts") == nil, "not a preset")
        var odd = perf; odd.baseResolution = 9999; odd.upscale = "x"; odd.displayQuality = 0.7; odd.edgeMask = "?"
        let c = odd.clamped()
        check(c.baseResolution == 0 && c.upscale == "metalfx" && c.displayQuality == 0.65 && c.edgeMask == "slight", "clamped \(c)")
        store.delete(saved.id)
        check(store.presets.isEmpty, "deleted")

        check(VXDeviceKind.from(model: "RealityDevice14,1") == .m2 && VXDeviceKind.from(model: "RealityDevice17,1") == .m5
              && VXDeviceKind.from(model: "arm64") == .m5 && VXDeviceKind.from(model: "x", override: "m2") == .m2, "device kind")
        check(VXDeviceKind.m2.rates == (90, 100) && VXDeviceKind.m5.rates == (100, 120), "rates")

        // what has changed since a preset
        check(VXPictureDiff.changes(from: std, to: std).isEmpty, "no change")
        check(VXPictureDiff.changes(from: perf, to: std).map(\.rawValue) == ["foveatedRendering"], "from performance: the foveation")
        check(VXPictureDiff.changes(from: std, to: q).map(\.rawValue) == ["baseResolution", "edgeMask"], "to quality")
        let last = VXLastPreset(defaults: fresh())
        check(last.id == nil, "no last preset")
        last.id = .builtIn(.quality)
        check(last.id == .builtIn(.quality), "last built-in")
        let u = UUID(); last.id = .custom(u)
        check(last.id == .custom(u), "last own")

        print(failures == 0 ? "xros presets: ok" : "xros presets: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
