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

        // picture extras: off / system default exports nothing; set, they persist and export; env wins and is clamped
        let pd = fresh()
        let p1 = VXSettings(defaults: pd, info: [:], environment: [:])
        check(p1.sharpen == nil && p1.renderQuality == nil && map(p1)["VXRT_SHARPEN"] == nil && map(p1)["VXRT_RENDER_QUALITY"] == nil, "sharpen and quality default off")
        p1.sharpen = 0.35; p1.renderQuality = 0.8
        let p2 = VXSettings(defaults: pd, info: [:], environment: [:])
        check(p2.sharpen == 0.35 && p2.renderQuality == 0.8 && map(p2)["VXRT_SHARPEN"] == "0.35" && map(p2)["VXRT_RENDER_QUALITY"] == "0.80", "sharpen and quality persist and export")
        p2.sharpen = 0; check(map(p2)["VXRT_SHARPEN"] == nil, "sharpen 0 exports nothing")
        p2.sharpen = nil; p2.renderQuality = nil
        check(pd.object(forKey: "vxrt.sharpen") == nil && pd.object(forKey: "vxrt.renderQuality") == nil, "off removes the stored values")
        let p3 = VXSettings(defaults: fresh(), info: [:], environment: ["VXRT_SHARPEN": "2", "VXRT_RENDER_QUALITY": "0.5"])
        check(p3.sharpen == 1 && p3.renderQuality == 0.5, "environment wins and is clamped")

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

        // the further settings: all game default (nothing exported) until picked
        d = fresh()
        s = VXSettings(defaults: d, info: [:], environment: [:])
        check(s.iniValues.isEmpty && map(s)["VXRT_INI_SET"] == nil && VXIniSetting.all.count == 19, "extra settings default to game default")
        s.setFlag("leftHanded", true); s.setFlag("compass", false); s.setNumber("comfortSize", 0.5); s.setNumber("eyeHeight", 500); s.setNumber("heightOffset", -3)
        check(map(s)["VXRT_INI_SET"] == "VRInput.bLeftHandedMode=1;VRComfort.fComfortModeSize=0.50;VR.fCharacterHeightOffset=-3;VR.fDefaultEyeHeight=160;Interface.bShowCompass=0", "extra ini \(map(s)["VXRT_INI_SET"] ?? "nil")")
        check(d.string(forKey: "vxrt.ini.leftHanded") == "1" && d.string(forKey: "vxrt.ini.compass") == "0", "extra stored under vxrt.ini.*")
        let e1 = VXSettings(defaults: d, info: [:], environment: [:])
        check(e1.flag("leftHanded") == true && e1.flag("compass") == false && e1.flag("crosshair") == nil && e1.number("comfortSize") == 0.5, "extra read back")
        e1.setFlag("leftHanded", nil); e1.setFlag("compass", nil)
        check(d.object(forKey: "vxrt.ini.leftHanded") == nil && d.object(forKey: "vxrt.ini.compass") == nil, "back to game default removes the stored value")
        // env beats saved, "game" means default; plist default sits below
        s = VXSettings(defaults: d, info: ["VXIni.crosshair": "0", "VXIni.alwaysRun": "1"], environment: ["VXRT_CROSSHAIR": "on", "VXRT_COMFORT_SIZE": "game", "VXRT_TELEPORT_DISTANCE": "9999"])
        check(s.flag("crosshair") == true && s.flag("alwaysRun") == true && s.number("comfortSize") == nil && s.number("teleportDistance") == 3000, "extra env/plist precedence")
        // every key is distinct and names a section.key
        check(Set(VXIniSetting.all.map { $0.iniName }).count == VXIniSetting.all.count && Set(VXIniSetting.all.map { $0.env }).count == VXIniSetting.all.count, "extra keys distinct")

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

        // the game's language: nothing chosen and nothing installed leaves the game's files alone
        let voices = { (set: Set<VXGameLanguage>) in { (l: VXGameLanguage) in set.contains(l) } }
        check(VXGameLanguage.resolve(choice: .auto, preset: nil, deviceLanguages: ["de-DE"], hasVoices: voices([])) == nil, "language: nothing chosen")
        check(VXGameLanguage.resolve(choice: .auto, preset: "", deviceLanguages: [], hasVoices: voices([.en])) == nil, "language: English voices are no choice")
        // one installed voice pack is the choice; two are none, then the installer's preset counts; a picked language beats both
        check(VXGameLanguage.resolve(choice: .auto, preset: "en", deviceLanguages: [], hasVoices: voices([.en, .de])) == .de, "language: the installed voices")
        check(VXGameLanguage.resolve(choice: .auto, preset: "fr_FR", deviceLanguages: [], hasVoices: voices([.de, .fr])) == .fr, "language: preset among two packs")
        check(VXGameLanguage.resolve(choice: .auto, preset: "de_DE", deviceLanguages: [], hasVoices: voices([])) == .de, "language: preset de_DE")
        check(VXGameLanguage.resolve(choice: .auto, preset: "device", deviceLanguages: ["ja-JP", "pl-PL", "de-DE"], hasVoices: voices([])) == .pl, "language: the headset's first known one")
        check(VXGameLanguage.resolve(choice: .auto, preset: "ko_KR", deviceLanguages: ["de-DE"], hasVoices: voices([])) == nil, "language: a preset the game has not")
        check(VXGameLanguage.resolve(choice: .it, preset: "de_DE", deviceLanguages: [], hasVoices: voices([.de])) == .it, "language: picked")
        // the overrides: the texts always, the voices only when their archive is there, swapped into the game's own list
        let shipped = VXGameLanguage.shippedArchiveList
        check(VXGameLanguage.iniSet(.de, hasVoices: false, archiveList: shipped).map { "\($0.key)=\($0.value)" } == ["General.sLanguage=GERMAN"], "language: texts only")
        let de = VXGameLanguage.iniSet(.de, hasVoices: true, archiveList: nil)
        check(de.count == 2 && de[1].key == "Archive.sResourceArchiveList2" && de[1].value == shipped.replacingOccurrences(of: "Voices_en0", with: "Voices_de0"), "language: German voices in the shipped list")
        let own = VXGameLanguage.iniSet(.en, hasVoices: true, archiveList: "Skyrim - Voices_de0.bsa, Mine.bsa")
        check(own.map(\.value) == ["ENGLISH", "Skyrim - Voices_en0.bsa, Mine.bsa"], "language: back to English in a German game folder")
        check(VXGameLanguage.iniSet(.fr, hasVoices: true, archiveList: "Mine.bsa")[1].value == "Skyrim - Voices_fr0.bsa, Mine.bsa", "language: a list without a voice archive")
        check(VXGameLanguage.archiveList(ofIni: "[General]\r\nsLanguage=ENGLISH\r\n[Archive]\r\nsResourceArchiveList=A.bsa\r\n sResourceArchiveList2 = B.bsa, C.bsa \r\n[Other]\r\nsResourceArchiveList2=no\r\n") == "B.bsa, C.bsa", "language: the list of an ini")
        // the store: a game folder with German voices exports both keys; the launch's own VXRT_INI_SET entries stay first
        let root = NSTemporaryDirectory() + "vxrt-lang-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root + "/SkyrimVR/Data", withIntermediateDirectories: true)
        try? "[Archive]\r\nsResourceArchiveList2=\(shipped)\r\n".write(toFile: root + "/SkyrimVR/Skyrim.ini", atomically: true, encoding: .isoLatin1)
        let l0 = VXSettings(defaults: fresh(), info: [:], environment: ["VXRT_GAME_ROOT": root])
        check(l0.gameLanguage == .auto && l0.effectiveGameLanguage == nil && map(l0)["VXRT_INI_SET"] == nil, "language: default exports nothing")
        let l1 = VXSettings(defaults: fresh(), info: ["VXGameLanguageDefault": "de_DE"], environment: ["VXRT_GAME_ROOT": root])
        check(l1.effectiveGameLanguage == .de && map(l1)["VXRT_INI_SET"] == "General.sLanguage=GERMAN", "language: preset, texts only")
        check(l0.gameLanguageNote.hasPrefix("Nothing is chosen") && l1.gameLanguageNote.hasPrefix("Automatic: Deutsch texts with the English voices") && l1.gameLanguageNote.contains("Skyrim - Voices_de0.bsa"), "language: the note without voices")
        FileManager.default.createFile(atPath: root + "/SkyrimVR/Data/Skyrim - Voices_de0.bsa", contents: Data())
        check(VXSettings(defaults: fresh(), info: [:], environment: ["VXRT_GAME_ROOT": root]).effectiveGameLanguage == nil, "language: an emptied voice archive is none")
        FileManager.default.createFile(atPath: root + "/SkyrimVR/Data/Skyrim - Voices_de0.bsa", contents: Data([1]))
        let ld = fresh()
        let l2 = VXSettings(defaults: ld, info: [:], environment: ["VXRT_GAME_ROOT": root, "VXRT_INI_SET": "VR.x=1"])
        check(l2.effectiveGameLanguage == .de && map(l2)["VXRT_INI_SET"] == "VR.x=1;General.sLanguage=GERMAN;Archive.sResourceArchiveList2=" + shipped.replacingOccurrences(of: "Voices_en0", with: "Voices_de0"), "language: installed voices")
        check(l2.gameLanguageNote == "Automatic: Deutsch, texts and voices.", "language: the note with voices")
        l2.gameLanguage = .en
        let l3 = VXSettings(defaults: ld, info: [:], environment: ["VXRT_GAME_ROOT": root])
        check(l3.gameLanguage == .en && map(l3)["VXRT_INI_SET"] == "General.sLanguage=ENGLISH", "language: a picked English persists (no English archive in this folder: the list stays)")
        check(VXSettings(defaults: ld, info: [:], environment: ["VXRT_GAME_ROOT": root, "VXRT_GAME_LANGUAGE": "ru"]).gameLanguage == .ru, "language: environment wins")
        try? FileManager.default.removeItem(atPath: root)

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
