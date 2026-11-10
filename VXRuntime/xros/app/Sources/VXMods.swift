// The launcher's read-only view of the mods the Mac prepared: <root>/mods.json, written by tools/mods.py (version 1).
// Nothing here changes anything: the runtime applies the pack at start (its overlay and Plugins.txt are already in place) and no mod
// toggles at run time. A mod is listed with whether it is enabled in the Mac's list and whether it is applied; SKSE mods are shown as
// enabled but greyed, and say where to configure them. Foundation only, so the mapping is tested on the Mac (tests/xros_mods_test.swift).
import Foundation

struct VXMod: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String            // "files", "plugin" or "skse"
    var enabled: Bool           // the Mac list's choice
    var active: Bool            // applied to this install (SKSE mods never are, yet)
    var priority: Int
    var memoryHintMB: Int?
    var sizeBytes: Int64?
    var note: String?
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, active, priority, note
        case memoryHintMB = "memory_hint_mb", sizeBytes = "size_bytes"
    }
}

struct VXModsFile: Codable, Equatable {
    var version: Int
    var profile: String
    var mods: [VXMod]
}

enum VXMods {
    /// Documents/root of the app, or VXRT_GAME_ROOT (the same folder the runtime uses, main.m).
    static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String {
        if let r = environment["VXRT_GAME_ROOT"], !r.isEmpty { return r }
        return home + "/Documents/root"
    }

    /// nil when there is no pack, it is unreadable, or it is not version 1.
    static func load(root: String) -> VXModsFile? {
        guard let data = FileManager.default.contents(atPath: root + "/mods.json"),
              let f = try? JSONDecoder().decode(VXModsFile.self, from: data), f.version == 1 else { return nil }
        return f
    }

    /// The launcher has no run-time toggling for any mod.
    static func canToggle(_ m: VXMod) -> Bool { false }

    static func status(_ m: VXMod) -> String {
        if m.kind == "skse" { return m.enabled ? "SKSE: configure on the Mac" : "SKSE: off" }
        if !m.enabled { return "Off" }
        return m.active ? "On" : "Not applied"
    }

    static func sizeText(_ bytes: Int64?) -> String {
        guard let b = bytes, b > 0 else { return "" }
        let mb = Double(b) / 1_000_000
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : String(format: "%.0f MB", mb)
    }
}
