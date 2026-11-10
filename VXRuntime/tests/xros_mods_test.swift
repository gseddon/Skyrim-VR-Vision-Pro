// Mac test of the launcher's read-only mods list (xros/app/Sources/VXMods.swift).
// Built with that file only: swiftc -parse-as-library -o build/xros_mods_test xros/app/Sources/VXMods.swift tests/xros_mods_test.swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

@main enum T {
    static func main() {
        let dir = NSTemporaryDirectory() + "vxrt-mods-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        check(VXMods.load(root: dir) == nil, "no mods.json -> nil")
        let json = """
        {"version":1,"profile":"default","merged":"merged","plugins":["a.esp"],"totals":{"active_mods":1},
         "mods":[{"id":"skyland","name":"Skyland AIO 1k","kind":"plugin","enabled":true,"active":true,"priority":10,"plugins":["a.esp"],"memory_hint_mb":250,"size_bytes":2632276741,"files":2057,"path":"mods/skyland","note":""},
                 {"id":"higgs","name":"HIGGS 1.10.10","kind":"skse","enabled":true,"active":false,"priority":40,"memory_hint_mb":null,"size_bytes":5128085,"note":"SKSE: configure on the Mac."},
                 {"id":"old","name":"Off one","kind":"files","enabled":false,"active":false,"priority":5,"note":"disabled in the list"},
                 {"id":"x","name":"Enabled, not applied","kind":"files","enabled":true,"active":false,"priority":6}]}
        """
        try! json.write(toFile: dir + "/mods.json", atomically: true, encoding: .utf8)
        guard let f = VXMods.load(root: dir) else { print("FAIL: load"); exit(1) }
        check(f.profile == "default" && f.mods.count == 4, "decoded \(f.mods.count) mods")
        let by = Dictionary(uniqueKeysWithValues: f.mods.map { ($0.id, $0) })
        check(VXMods.status(by["skyland"]!) == "On", "applied mod is On")
        check(VXMods.status(by["higgs"]!) == "SKSE: configure on the Mac", "SKSE mod: configure on the Mac")
        check(VXMods.status(by["old"]!) == "Off", "disabled mod is Off")
        check(VXMods.status(by["x"]!) == "Not applied", "enabled but not applied")
        check(f.mods.allSatisfy { !VXMods.canToggle($0) }, "no mod can be toggled at run time")
        check(VXMods.sizeText(by["skyland"]!.sizeBytes) == "2.6 GB" && VXMods.sizeText(by["higgs"]!.sizeBytes) == "5 MB" && VXMods.sizeText(nil) == "", "size text")
        check(by["skyland"]!.memoryHintMB == 250 && by["higgs"]!.memoryHintMB == nil, "memory hint optional")
        try! #"{"version":2,"profile":"p","mods":[]}"#.write(toFile: dir + "/mods.json", atomically: true, encoding: .utf8)
        check(VXMods.load(root: dir) == nil, "other versions are not read")
        try! "not json".write(toFile: dir + "/mods.json", atomically: true, encoding: .utf8)
        check(VXMods.load(root: dir) == nil, "garbage is not read")
        check(VXMods.defaultRoot(environment: ["VXRT_GAME_ROOT": "/r"], home: "/h") == "/r" && VXMods.defaultRoot(environment: [:], home: "/h") == "/h/Documents/root", "default root")
        print(failures == 0 ? "xros mods: ok" : "xros mods: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
