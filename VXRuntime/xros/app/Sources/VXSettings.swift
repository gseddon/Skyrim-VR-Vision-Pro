// The app's user settings: a store with Klepton's persistence conventions, and the mapping from the stored values to the runtime's VXRT_*
// environment, which stays canonical (the C side reads it with getenv at first use, so it is set once, before the program starts: VXApp.swift,
// VXStartView.swift).
//
// Adapted from Klepton (MIT, Copyright (c) 2026 Max Thomas; fork https://github.com/myMartek/Klepton at a7bad301c10b03e7d615ae8d51033146c373bcb5,
// the repository AVP Play builds its apps from; license text third_party/klepton_openxr/LICENSE). Reference files in the fork, visionos/Sources/:
//   KleptonTuning.swift   KleptonRendering: the render scale stored under UserDefaults "klepton.renderScale", per-title default from Info.plist
//                         KLRenderScaleDefault, the range 0.5...1.0 (:252, :427-455, :525), env override KL_OVRP_RENDER_SCALE (:562);
//   KleptonChroma.swift   KLChromaSettings / KleptonChroma: "handMatting" in one Codable JSON blob under "klepton.chroma", default from Info.plist
//                         KLHandMattingDefault, "the environment wins where it is explicitly set, then the saved settings, then the defaults" (:21-122);
//   KleptonApp.swift      klEnvOn (KL_AUTOBOOT, KL_OVERLAYS, KL_EXIT_ON_BACKGROUND), Info.plist KLAutoBootDefault.
// Reimplemented here, not copied: the key names, the order of precedence and the Info.plist default names are Klepton's, so that AVP Play can preset
// them the way it does for Klepton apps. Differences: the hand toggle defaults to hidden when the Info.plist has no KLHandMattingDefault (Klepton's
// default is shown); the blob is written with the fields this app has (handMatting) and read tolerantly, so a Klepton-written blob is understood.
// Keys that Klepton has no equivalent for are namespaced "vxrt.".
//
// Foundation and Combine only, so that the mapping is tested on the Mac (tests/xros_settings_test.swift).
import Combine
import Foundation

// Environment as a dictionary so tests can inject one.
typealias VXEnvironment = [String: String]

struct VXHandsBlob: Codable, Equatable {
    var handMatting: Bool
    private enum CodingKeys: String, CodingKey { case handMatting }
    init(handMatting: Bool) { self.handMatting = handMatting }
    init(from d: Decoder) throws {
        // decodeIfPresent: a blob from an older build, or one Klepton wrote with its chroma fields, is read rather than rejected.
        let c = try d.container(keyedBy: CodingKeys.self)
        handMatting = try c.decodeIfPresent(Bool.self, forKey: .handMatting) ?? false
    }
}

// Latency choice, mapped to the runtime's pair gate VXRT_GATE: smart (default), lower latency = one, max throughput = off.
enum VXLatency: String, CaseIterable, Identifiable {
    case smart, lower, throughput
    var id: String { rawValue }
    var gate: String { self == .smart ? "smart" : self == .lower ? "one" : "off" }
    var gateMode: Int { self == .smart ? 2 : self == .lower ? 1 : 0 }   // vx_xros_set_gate_mode
    init?(stored: String) {
        if stored == "smoother" { self = .throughput; return }   // an older build's name for "off"
        self.init(rawValue: stored)
    }
}

// Upscaling: MetalFX spatial (default) or the presenter's bilinear sampler. VXRT_UPSCALE.
enum VXUpscale: String, CaseIterable, Identifiable {
    case metalfx, bilinear
    var id: String { rawValue }
}

// Skyrim VR's own gameplay choices, written over its SkyrimPrefs.ini values through VXRT_INI_SET (client.c). "Game default" writes nothing, so the
// game's own value stays: a key is only overridden when the player picked one here. Keys are strings of the game's exe, section [VRInput]
// (research/2026-11-11-skyrim-vr-gameplay-settings.md).
// Turning: Snap = bGamepadLookAngleSnapping 1 (smoothing 0), Smooth = bGamepadLookAngleSnapping 0.
enum VXTurn: String, CaseIterable, Identifiable {
    case game, snap, smooth
    var id: String { rawValue }
    var iniSet: [(key: String, value: String)] {
        switch self {
        case .game: return []
        case .snap: return [("VRInput.bGamepadLookAngleSnapping", "1"), ("VRInput.bGamepadLookAngleSnapSmoothing", "0")]
        case .smooth: return [("VRInput.bGamepadLookAngleSnapping", "0")]
        }
    }
}
// Movement: Teleport = bDirectMovementWithWands 0, Walk (direct, with the stick) = 1.
enum VXMove: String, CaseIterable, Identifiable {
    case game, teleport, walk
    var id: String { rawValue }
    var iniSet: [(key: String, value: String)] {
        switch self {
        case .game: return []
        case .teleport: return [("VRInput.bDirectMovementWithWands", "0")]
        case .walk: return [("VRInput.bDirectMovementWithWands", "1")]
        }
    }
}

// More of the game's own settings, each "Game default" (nothing written) until the player picks a value. A yes/no is on, off or default; a number is
// default or a value in a range. Keys are strings of the game's exe (research/2026-11-11-skyrim-vr-gameplay-settings.md). Number ranges: the
// game's own Min/Max keys exist only for the snap angle and turn speed; the rest are conservative bounds, defaults and units NOT verified.
struct VXIniSetting: Identifiable {
    enum Group: String, CaseIterable { case controls = "Controls", comfort = "Comfort", body = "Body", interface = "Interface", teleport = "Teleport" }
    enum Kind { case flag, number(range: ClosedRange<Double>, step: Double, unit: String) }
    let id: String, env: String, section: String, key: String, title: String, group: Group, kind: Kind
    var iniName: String { "\(section).\(key)" }
    static func flag(_ id: String, _ env: String, _ section: String, _ key: String, _ title: String, _ group: Group) -> VXIniSetting {
        VXIniSetting(id: id, env: env, section: section, key: key, title: title, group: group, kind: .flag)
    }
    static func number(_ id: String, _ env: String, _ section: String, _ key: String, _ title: String, _ group: Group, _ r: ClosedRange<Double>, _ step: Double, _ unit: String) -> VXIniSetting {
        VXIniSetting(id: id, env: env, section: section, key: key, title: title, group: group, kind: .number(range: r, step: step, unit: unit))
    }
    static let all: [VXIniSetting] = [
        .flag("leftHanded", "VXRT_LEFT_HANDED", "VRInput", "bLeftHandedMode", "Left-handed", .controls),
        .flag("wandDirection", "VXRT_WAND_DIRECTION", "VRInput", "bUseWandDirectionalMovement", "Walk in the direction of the controller", .controls),
        .flag("alwaysRun", "VXRT_ALWAYS_RUN", "Controls", "bAlwaysRunByDefault", "Always run", .controls),
        .flag("comfortTurning", "VXRT_COMFORT_TURNING", "VRComfort", "bComfortModeWhileTurning", "Comfort vignette while turning", .comfort),
        .flag("comfortMoving", "VXRT_COMFORT_MOVING", "VRComfort", "bComfortModeWhileMoving", "Comfort vignette while moving", .comfort),
        .number("comfortSize", "VXRT_COMFORT_SIZE", "VRComfort", "fComfortModeSize", "Comfort vignette size", .comfort, 0...1, 0.05, ""),
        .flag("comfortSneak", "VXRT_COMFORT_SNEAK", "VR", "bComfortSneak", "Comfort sneak", .comfort),
        .number("heightOffset", "VXRT_HEIGHT_OFFSET", "VR", "fCharacterHeightOffset", "Character height offset", .body, -20...20, 1, ""),
        .number("eyeHeight", "VXRT_GAME_EYE_HEIGHT", "VR", "fDefaultEyeHeight", "Default eye height", .body, 80...160, 1, ""),
        .flag("handsSheathed", "VXRT_HANDS_SHEATHED", "VRInput", "bShowHandsWhileSheathed", "Show hands while weapons are sheathed", .body),
        .flag("handsAlways", "VXRT_HANDS_ALWAYS", "VR", "bAlwaysShowHands", "Always show hands", .body),
        .flag("subtitlesGeneral", "VXRT_SUBTITLES_GENERAL", "Interface", "bGeneralSubtitles", "General subtitles", .interface),
        .flag("subtitlesDialogue", "VXRT_SUBTITLES_DIALOGUE", "Interface", "bDialogueSubtitles", "Dialogue subtitles", .interface),
        .flag("subtitlesSpeaker", "VXRT_SUBTITLES_SPEAKER", "Interface", "bShowSubtitleSpeakerName", "Speaker name in subtitles", .interface),
        .flag("compass", "VXRT_COMPASS", "Interface", "bShowCompass", "Compass", .interface),
        .flag("crosshair", "VXRT_CROSSHAIR", "Interface", "bShowCrosshair", "Crosshair", .interface),
        .flag("hudMessages", "VXRT_HUD_MESSAGES", "Interface", "bShowHUDMessages", "HUD messages", .interface),
        .flag("teleportFade", "VXRT_TELEPORT_FADE", "VRTeleport", "bTeleportFade", "Fade the screen when teleporting", .teleport),
        .number("teleportDistance", "VXRT_TELEPORT_DISTANCE", "VRTeleport", "fMaxTeleportDistance", "Maximum teleport distance", .teleport, 100...3000, 50, ""),
    ]
    // A stored/env text -> the text kept ("1"/"0" or a clamped number), nil = game default.
    func normalize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch kind {
        case .flag: return ["1", "on", "true", "yes"].contains(t) ? "1" : ["0", "off", "false", "no"].contains(t) ? "0" : nil
        case .number(let r, _, _): return Double(t).map { VXSettings.num($0, r) }
        }
    }
}

final class VXSettings: ObservableObject {
    static let shared = VXSettings()
    // Called when the latency choice changes, so a running game's gate follows at once (VXApp.swift sets it in the xrizer build).
    nonisolated(unsafe) static var latencyHook: ((VXLatency) -> Void)?

    // UserDefaults keys. The first two are Klepton's.
    static let renderScaleKey = "klepton.renderScale"
    static let handsKey = "klepton.chroma"
    static let latencyKey = "vxrt.latency"
    static let upscaleKey = "vxrt.upscale"
    static let autoStartKey = "vxrt.startAutomatically"
    static let predictKey = "vxrt.predictMs"
    static let eyeHeightKey = "vxrt.stageEyeHeight"
    static let turnKey = "vxrt.turn"
    static let snapAngleKey = "vxrt.snapAngle"
    static let turnSpeedKey = "vxrt.turnSpeed"
    static let moveKey = "vxrt.move"

    static let renderScaleRange = 0.5...1.0
    static let renderScaleBuiltIn = 0.75
    static let eyeHeightRange = 1.0...2.2
    static let eyeHeightBuiltIn = 1.6
    static let snapAngleRange = 10.0...90.0
    static let snapAngleBuiltIn = 30.0
    static let turnSpeedRange = 0.1...10.0
    static let turnSpeedBuiltIn = 1.0
    static let predictRange = 0.0...140.0
    static let autoStartDelay = 5

    private let defaults: UserDefaults
    private let info: [String: Any]
    let environment: VXEnvironment

    // Picture: the size the game renders at, as a fraction of the drawable (next launch).
    @Published var renderScale: Double { didSet { if !suppress { defaults.set(renderScale, forKey: Self.renderScaleKey) } } }
    // Upscaling of the game's eye to the display (next launch).
    @Published var upscale: VXUpscale { didSet { if !suppress { defaults.set(upscale.rawValue, forKey: Self.upscaleKey) } } }
    // Latency: the pair gate, read per frame, so it applies at once.
    @Published var latency: VXLatency { didSet { if !suppress { defaults.set(latency.rawValue, forKey: Self.latencyKey); Self.latencyHook?(latency) } } }
    // Whether the wearer's real hands and arms show over the game. Live: the immersive scene observes it (VXApp.swift).
    // While the keyboard window is open (VXKeyboard.swift) the wearer's hands are shown whatever the setting says, so the fingers can be
    // seen typing; not saved, and off again when the keyboard closes. The scene shows the hands when `handsVisible`.
    @Published var keyboardHands = false
    var handsVisible: Bool { showHands || keyboardHands }
    @Published var showHands: Bool {
        didSet { if !suppress, let d = try? JSONEncoder().encode(VXHandsBlob(handMatting: showHands)) { defaults.set(d, forKey: Self.handsKey) } }
    }
    @Published var startAutomatically: Bool { didSet { if !suppress { defaults.set(startAutomatically, forKey: Self.autoStartKey) } } }
    // Head-pose prediction horizon in ms; nil = follow the measured delay (the runtime's default).
    @Published var predictMs: Double? {
        didSet {
            guard !suppress else { return }
            if let v = predictMs { defaults.set(v, forKey: Self.predictKey) } else { defaults.removeObject(forKey: Self.predictKey) }
        }
    }
    // Standing eye height the stage is dropped by (m); nil = the runtime's 1.6 m.
    @Published var stageEyeHeight: Double? {
        didSet {
            guard !suppress else { return }
            if let v = stageEyeHeight { defaults.set(v, forKey: Self.eyeHeightKey) } else { defaults.removeObject(forKey: Self.eyeHeightKey) }
        }
    }
    // Gameplay (Skyrim VR's own settings; .game / nil = leave the game's own value alone).
    @Published var turn: VXTurn { didSet { if !suppress { defaults.set(turn.rawValue, forKey: Self.turnKey) } } }
    @Published var move: VXMove { didSet { if !suppress { defaults.set(move.rawValue, forKey: Self.moveKey) } } }
    // Snap angle in degrees (fGamepadLookAngleSnapAmount); nil = the game's.
    @Published var snapAngle: Double? {
        didSet {
            guard !suppress else { return }
            if let v = snapAngle { defaults.set(v, forKey: Self.snapAngleKey) } else { defaults.removeObject(forKey: Self.snapAngleKey) }
        }
    }
    // Smooth turn speed (fGamepadLookAngleSnapSmoothingSpeed); nil = the game's.
    @Published var turnSpeed: Double? {
        didSet {
            guard !suppress else { return }
            if let v = turnSpeed { defaults.set(v, forKey: Self.turnSpeedKey) } else { defaults.removeObject(forKey: Self.turnSpeedKey) }
        }
    }
    // The extra settings above: id -> "1"/"0"/number text; absent = game default.
    @Published var iniValues: [String: String] {
        didSet {
            guard !suppress else { return }
            for s in VXIniSetting.all {
                if let v = iniValues[s.id] { defaults.set(v, forKey: Self.iniKeyPrefix + s.id) } else { defaults.removeObject(forKey: Self.iniKeyPrefix + s.id) }
            }
        }
    }
    static let iniKeyPrefix = "vxrt.ini."
    func flag(_ id: String) -> Bool? { iniValues[id].map { $0 == "1" } }
    func setFlag(_ id: String, _ v: Bool?) { iniValues[id] = v.map { $0 ? "1" : "0" } }
    func number(_ id: String) -> Double? { iniValues[id].flatMap(Double.init) }
    func setNumber(_ id: String, _ v: Double?) { iniValues[id] = v.map { String($0) } }
    private var suppress = true

    static func clampScale(_ v: Double) -> Double {
        let r = ((v / 0.05).rounded() * 5).rounded() / 100
        return min(max(r, renderScaleRange.lowerBound), renderScaleRange.upperBound)
    }
    private static func flag(_ v: String?) -> Bool? { v.map { $0 != "0" && !$0.isEmpty } }

    // Precedence, as Klepton's: an explicitly set environment variable, then the saved choice, then the Info.plist default, then the built-in.
    init(defaults: UserDefaults = .standard, info: [String: Any] = Bundle.main.infoDictionary ?? [:],
         environment: VXEnvironment = ProcessInfo.processInfo.environment) {
        self.defaults = defaults; self.info = info; self.environment = environment
        let plistScale = (info["KLRenderScaleDefault"] as? String).flatMap(Double.init)
        let envScale = (environment["VXRT_RENDER_SCALE"] ?? environment["KL_OVRP_RENDER_SCALE"]).flatMap(Double.init)
        let scale = envScale ?? (defaults.object(forKey: Self.renderScaleKey) as? Double) ?? plistScale ?? Self.renderScaleBuiltIn
        renderScale = Self.clampScale(scale)

        let plistHands = (info["KLHandMattingDefault"] as? String).map { $0 != "0" } ?? false
        var hands = plistHands
        if let d = defaults.data(forKey: Self.handsKey), let b = try? JSONDecoder().decode(VXHandsBlob.self, from: d) { hands = b.handMatting }
        if let v = Self.flag(environment["VXRT_SHOW_HANDS"] ?? environment["KL_HAND_MATTING"]) { hands = v }
        showHands = hands

        var lat: VXLatency = (info["VXLatencyDefault"] as? String).flatMap(VXLatency.init(stored:)) ?? .smart
        if let s = defaults.string(forKey: Self.latencyKey), let l = VXLatency(stored: s) { lat = l }
        if let p = environment["VXRT_PAIRS_IN_FLIGHT"].flatMap(Int.init) { lat = p == 0 ? .throughput : .lower }
        if let g = environment["VXRT_GATE"] { lat = g == "off" ? .throughput : g == "one" ? .lower : g == "smart" ? .smart : lat }
        latency = lat

        var up: VXUpscale = (info["VXUpscaleDefault"] as? String).flatMap(VXUpscale.init(rawValue:)) ?? .metalfx
        if let s = defaults.string(forKey: Self.upscaleKey), let u = VXUpscale(rawValue: s) { up = u }
        if let u = environment["VXRT_UPSCALE"].flatMap(VXUpscale.init(rawValue:)) { up = u }
        upscale = up

        var auto = (info["KLAutoBootDefault"] as? String).map { $0 == "1" } ?? false
        if let v = defaults.object(forKey: Self.autoStartKey) as? Bool { auto = v }
        if let v = Self.flag(environment["VXRT_START_AUTOMATICALLY"] ?? environment["KL_AUTOBOOT"]) { auto = v }
        startAutomatically = auto

        predictMs = environment["VXRT_PREDICT_MS"].flatMap(Double.init) ?? (defaults.object(forKey: Self.predictKey) as? Double)
        stageEyeHeight = environment["VXRT_STAGE_EYE_HEIGHT"].flatMap(Double.init) ?? (defaults.object(forKey: Self.eyeHeightKey) as? Double)
        // Gameplay: env VXRT_TURN / VXRT_SNAP_ANGLE / VXRT_TURN_SPEED / VXRT_MOVE, then the saved choice, then the Info.plist default
        // (VXTurnDefault, VXMoveDefault), then .game.
        var t: VXTurn = (info["VXTurnDefault"] as? String).flatMap(VXTurn.init(rawValue:)) ?? .game
        if let s = defaults.string(forKey: Self.turnKey), let v = VXTurn(rawValue: s) { t = v }
        if let v = environment["VXRT_TURN"].flatMap(VXTurn.init(rawValue:)) { t = v }
        turn = t
        var m: VXMove = (info["VXMoveDefault"] as? String).flatMap(VXMove.init(rawValue:)) ?? .game
        if let s = defaults.string(forKey: Self.moveKey), let v = VXMove(rawValue: s) { m = v }
        if let v = environment["VXRT_MOVE"].flatMap(VXMove.init(rawValue:)) { m = v }
        move = m
        snapAngle = environment["VXRT_SNAP_ANGLE"].flatMap(Double.init) ?? (defaults.object(forKey: Self.snapAngleKey) as? Double)
        turnSpeed = environment["VXRT_TURN_SPEED"].flatMap(Double.init) ?? (defaults.object(forKey: Self.turnSpeedKey) as? Double)
        // The extra settings: env (VXRT_*; "game" = default), then saved, then Info.plist "VXIni.<id>", else game default.
        var vals: [String: String] = [:]
        for s in VXIniSetting.all {
            var v = (info["VXIni." + s.id] as? String).flatMap(s.normalize)
            if let st = defaults.string(forKey: Self.iniKeyPrefix + s.id) { v = s.normalize(st) }
            if let e = environment[s.env] { v = s.normalize(e) }
            if let v = v { vals[s.id] = v }
        }
        iniValues = vals
        suppress = false
    }

    static func num(_ v: Double, _ r: ClosedRange<Double>) -> String {
        let c = min(max(v, r.lowerBound), r.upperBound)
        return c == c.rounded() ? String(Int(c)) : String(format: "%.2f", c)
    }
    // The Skyrim*.ini overrides these settings stand for, "Section.Key=Value": first the ones a launch already put in VXRT_INI_SET (the first
    // match wins in client.c, so the launch's own value beats a setting).
    func iniOverrides() -> [String] {
        var out = environment["VXRT_INI_SET"].map { $0.split(separator: ";").map(String.init) } ?? []
        var mine = turn.iniSet + move.iniSet
        if let a = snapAngle { mine.append(("VRInput.fGamepadLookAngleSnapAmount", Self.num(a, Self.snapAngleRange))) }
        if let v = turnSpeed { mine.append(("VRInput.fGamepadLookAngleSnapSmoothingSpeed", Self.num(v, Self.turnSpeedRange))) }
        for s in VXIniSetting.all { if let v = iniValues[s.id].flatMap(s.normalize) { mine.append((s.iniName, v)) } }
        out += mine.map { "\($0.key)=\($0.value)" }
        return out
    }

    // The VXRT_* variables the stored settings stand for. Set with overwrite off (VXSettings.applyEnvironment), so a variable the launch
    // itself set (devicectl --environment-variables) is never replaced.
    func exports() -> [(name: String, value: String)] {
        var out: [(String, String)] = [
            ("VXRT_RENDER_SCALE", String(format: "%.2f", renderScale)),
            ("VXRT_UPSCALE", upscale.rawValue),
            ("VXRT_GATE", latency.gate),
        ]
        if let p = predictMs { out.append(("VXRT_PREDICT_MS", String(format: "%.0f", min(max(p, Self.predictRange.lowerBound), Self.predictRange.upperBound)))) }
        if let h = stageEyeHeight { out.append(("VXRT_STAGE_EYE_HEIGHT", String(format: "%.2f", min(max(h, Self.eyeHeightRange.lowerBound), Self.eyeHeightRange.upperBound)))) }
        let ini = iniOverrides()
        if !ini.isEmpty { out.append(("VXRT_INI_SET", ini.joined(separator: ";"))) }
        return out
    }

    // Before the program starts (never later: the runtime reads these once, lazily). Returns what was set and what was left to the launch.
    @discardableResult
    func applyEnvironment() -> (set: [String], kept: [String]) {
        var set: [String] = [], kept: [String] = []
        for (k, v) in exports() {
            // VXRT_INI_SET already carries the launch's own entries first (iniOverrides), so it is the one variable that is replaced.
            if getenv(k) != nil && k != "VXRT_INI_SET" { kept.append(k); continue }
            setenv(k, v, 1); set.append("\(k)=\(v)")
        }
        return (set, kept)
    }
}

// Whether the start window gates the program's start: the build asks for it (Info.plist VXStartWindow = 1), the launch is the default one (no -test or -game
// argument: the harness and the tests start their program at once), and VXRT_START_WINDOW=0 is not set.
enum VXLaunchGate {
    static func enabled(info: [String: Any], environment: VXEnvironment, defaultLaunch: Bool) -> Bool {
        (info["VXStartWindow"] as? String) == "1" && environment["VXRT_START_WINDOW"] != "0" && defaultLaunch
    }
}

// The controller-alignment values in Documents/vxrt_sense.txt, which VXSenseTune re-reads once a second: "pitch=<deg> yaw=<deg> roll=<deg>
// pos=x,y,z" (degrees about the grip's X, Y, Z; metres in the grip frame).
struct VXSenseValues: Equatable {
    var pitch: Float = 0, yaw: Float = 0, roll: Float = 0
    var pos = SIMD3<Float>(0, 0, 0)
    static func path(home: String = NSHomeDirectory()) -> String { (home as NSString).appendingPathComponent("Documents/vxrt_sense.txt") }
    static func parse(_ text: String) -> VXSenseValues {
        var t = VXSenseValues()
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == ";" }) {
            let kv = word.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "pitch": if let v = Float(kv[1]) { t.pitch = v }
            case "yaw": if let v = Float(kv[1]) { t.yaw = v }
            case "roll": if let v = Float(kv[1]) { t.roll = v }
            case "pos": let p = kv[1].split(separator: ",").compactMap { Float($0) }; if p.count == 3 { t.pos = SIMD3(p[0], p[1], p[2]) }
            default: break
            }
        }
        return t
    }
    var text: String { String(format: "pitch=%.2f yaw=%.2f roll=%.2f pos=%.4f,%.4f,%.4f\n", pitch, yaw, roll, pos.x, pos.y, pos.z) }
    static func load(path: String = path()) -> VXSenseValues {
        (try? String(contentsOfFile: path, encoding: .utf8)).map(parse) ?? VXSenseValues()
    }
    func save(path: String = VXSenseValues.path()) { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
    static func reset(path: String = path()) { try? FileManager.default.removeItem(atPath: path) }
}
