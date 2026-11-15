// The start window and the settings page. A Klepton-style front (Start, Settings, status, version stamp), shown instead of booting straight into
// the game when the build asks for it (Info.plist VXStartWindow, VXLaunchGate). Start applies the settings to the environment and only then opens
// the display window, whose view starts the program (main.m vxrt_boot), so everything the runtime reads at first use sees the chosen values.
//
// Layout and wording adapted from Klepton (MIT, Copyright (c) 2026 Max Thomas; fork https://github.com/myMartek/Klepton at
// a7bad301c10b03e7d615ae8d51033146c373bcb5; license text third_party/klepton_openxr/LICENSE), visionos/Sources/KleptonApp.swift: BootView.startFront
// (:1132-1300: title, large Start, Settings, status line, version stamp in the corner), BootView.settingsPage (:1342-1415: NavigationStack, GroupBox
// sections, grey callout explanations, an Advanced DisclosureGroup, Done), PlayerSettingsView (:719-840: Picture, Your hands, "Changes to the picture
// apply the next time you start the game"), KleptonTuning.swift TuningView (:106) for the alignment sliders. Reimplemented, English only; the Klepton
// runtime seams (kl_*) are not used. Branding is text only: no game art is part of this project.
//
// The start picture is optional and not in the repository: a file bundle/StartHero.png in the app's resources. Whoever builds the app (an
// installer, with a picture of the player's own) puts StartHero.png into the folder the project copies as "bundle" before xros-app: for the
// Skyrim app (XROS_XRIZER_GAME=1) that is $(XROS_DIR)/bundle in the Makefile. The front then shows it behind the title: filled, a gradient to
// black under the text, the text at the bottom. Without the file the front is the plain window: text in the middle, no picture.
import SwiftUI
import UIKit

#if XRIZER_XROS_FIXTURE
private func loadStage() -> Int { Int(vx_xros_load_stage()) }
#else
private func loadStage() -> Int { 0 }
#endif

// What the start window knows about the run. The program starts once per process (Klepton: "the guest boots once per process").
final class VXLauncher: ObservableObject {
    static let shared = VXLauncher()
    enum Phase { case idle, countdown(Int), started }
    @Published var phase: Phase = .idle
    var started: Bool { if case .started = phase { return true }; return false }
    private(set) var startedAt: Date?
    // Apply the settings to the environment, then let the display view appear (it starts the program). Once.
    func start(openDisplay: () -> Void) {
        guard !started else { return }
        let r = VXSettings.shared.applyEnvironment()
        vxrt_jlog("settings_applied", "\"set\":\"\(VXSettings.logText(r.set.joined(separator: " ")))\",\"kept\":\"\(r.kept.joined(separator: " "))\"")
        phase = .started
        startedAt = Date()
        openDisplay()
        vxrt_boot_fallback()      // (the program still starts after a few seconds if the display view never appears)
    }
}

struct VXStartView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var launcher = VXLauncher.shared
    @ObservedObject private var settings = VXSettings.shared
    @State private var showSettings = ProcessInfo.processInfo.environment["VXRT_START_SETTINGS"] == "1"   // (a scripted launch can show the settings page)

    private static let title = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Skyrim VR"
    /// The start picture, when the app was built with one (see the note on top).
    static let hero: UIImage? = Bundle.main.resourcePath.flatMap { UIImage(contentsOfFile: $0 + "/bundle/StartHero.png") }
    private static let versionStamp: String? = {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return nil }
        let build = (info?["CFBundleVersion"] as? String) ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }()

    var body: some View {
        Group { if showSettings { VXSettingsPage(done: { showSettings = false }) } else { front } }
            .task { await autoStart() }
            // After Start, once the immersive space is open, this window is closed (it used to stay, reading "Running", in front of the game),
            // and again whenever the space is confirmed open after a pause or a reopen, or if the system brought this scene back.
            .onReceive(NotificationCenter.default.publisher(for: .vxSpaceOpened)) { _ in
                if launcher.started { dismissWindow(id: "start"); vxrt_jlog("start_window_dismissed", nil) }
            }
            .onAppear { if launcher.started && VXLifecycle.spaceOpen { dismissWindow(id: "start") } }
    }

    private func startNow() { launcher.start { openWindow(id: "display") } }

    // "Start automatically": a countdown with Cancel and Settings, so that the settings stay reachable (a crown press ends the app, and the
    // next launch would otherwise start the game again before anything could be changed).
    private func autoStart() async {
        guard settings.startAutomatically, case .idle = launcher.phase, !showSettings else { return }
        for left in stride(from: VXSettings.autoStartDelay, to: 0, by: -1) {
            launcher.phase = .countdown(left)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard case .countdown = launcher.phase else { return }       // cancelled
        }
        startNow()
        dismissWindow(id: "start")
    }

    private var front: some View {
        ZStack(alignment: .bottom) {
            if let hero = Self.hero {
                Image(uiImage: hero).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom))
                    .accessibilityHidden(true)
            }
            frontContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if let stamp = Self.versionStamp {
                Text(stamp).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize().padding(.trailing, 48).padding(.bottom, 20)
            }
        }
    }

    // With a picture the text sits at the bottom, on the dark end of the gradient; without one it stays in the middle of the window.
    private var frontContent: some View {
        VStack(spacing: 22) {
            Spacer()
            Text(Self.title).font(.extraLargeTitle.bold()).shadow(color: Self.hero == nil ? .clear : .black.opacity(0.33), radius: 10)
            Text("Skyrim VR on Apple Vision Pro, running natively with Sense controllers.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            statusLine
            HStack(spacing: 18) {
                Button {
                    startNow()
                } label: {
                    Label(launcher.started ? "Running" : "Start", systemImage: launcher.started ? "checkmark.circle.fill" : "play.fill").frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent).tint(.white).controlSize(.extraLarge)
                .foregroundStyle(launcher.started ? Color.secondary : Color.black)
                .disabled(launcher.started)
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .controlSize(.extraLarge)
                if case .countdown = launcher.phase {
                    Button("Cancel") { launcher.phase = .idle }.controlSize(.extraLarge)
                }
            }
            if launcher.started {
                Text("The game is in the immersive space. Resolution applies the next time you open the app.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            if Self.hero == nil { Spacer() }
        }
        .padding(40)
        .padding(.bottom, Self.hero == nil ? 0 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var statusLine: some View {
        if case .countdown(let n) = launcher.phase {
            Label("Starting in \(n) s. Cancel to change settings first.", systemImage: "timer").font(.headline)
        } else if launcher.started {
            // The runtime's own milestones, as the loading card in the space shows them.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let labels = ["Starting", "Preparing the game", "Loading the game", "Almost ready", "Ready"]
                Label(labels[min(max(loadStage(), 0), 4)], systemImage: "hourglass").font(.headline)
            }
        }
    }
}

// Read-only: the mods the Mac prepared (VXMods.swift, <root>/mods.json). Every toggle is disabled; nothing changes at run time.
struct VXModsList: View {
    // Read when the section appears (not once at view creation): the file may be copied while the window is open, and the root
    // folder only exists once the runtime has made it.
    @State private var file: VXModsFile?
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let file = file, !file.mods.isEmpty {
                ForEach(file.mods) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: .constant(m.enabled)) {
                            HStack {
                                Text(m.name)
                                Spacer()
                                Text(VXMods.sizeText(m.sizeBytes)).foregroundStyle(.secondary)
                                Text(VXMods.status(m)).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!VXMods.canToggle(m))
                        if m.kind == "skse" {
                            Text("SKSE: configure on the Mac").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Profile \(file.profile). Mods are chosen on the Mac (tools/mods.py) and apply when the app starts; none can be switched here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(loaded ? "No mods installed. Mods are prepared on the Mac and copied to the headset." : "Reading the mods list…").font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { file = VXMods.load(root: VXMods.defaultRoot()); loaded = true }
    }
}

struct VXSettingsPage: View {
    let done: () -> Void
    @ObservedObject private var settings = VXSettings.shared
    @ObservedObject private var launcher = VXLauncher.shared
    @State private var sense = VXSenseValues.load()
    @State private var advancedOpen = ProcessInfo.processInfo.environment["VXRT_START_ADVANCED"] == "1"

    private func note(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Picture") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Resolution")
                                Slider(value: Binding(get: { settings.renderScale }, set: { settings.renderScale = VXSettings.clampScale($0) }),
                                       in: VXSettings.renderScaleRange, step: 0.05)
                                Text(String(format: "%.0f%%", settings.renderScale * 100)).font(.system(.body, design: .monospaced)).frame(width: 70)
                            }
                            note("The size the game draws each eye at, as a share of the display's. Lower is smoother on a busy scene; higher is sharper. 65% with MetalFX is the default.")
                            Picker("Unseen edge", selection: $settings.edgeMask) {
                                Text("Draw everything").tag(VXEdgeMask.off)
                                Text("Skip a little").tag(VXEdgeMask.slight)
                                Text("Skip more").tag(VXEdgeMask.standard)
                            }.pickerStyle(.segmented)
                            note("The game can leave out the edge of the picture that the lenses do not show, which makes it run more smoothly. “Skip more” is the default. If you see a black bar or black corners in the game, choose less here; “Draw everything” never shows one. Next launch.")
                            Picker("Upscaling", selection: $settings.upscale) {
                                Text("MetalFX").tag(VXUpscale.metalfx)
                                Text("Bilinear").tag(VXUpscale.bilinear)
                            }.pickerStyle(.segmented)
                            note(settings.upscale == .metalfx
                                 ? "Apple's MetalFX spatial upscaler brings the game's picture up to the display's size: sharper than plain scaling."
                                 : "The display's own sampler stretches the picture: softer, with no extra work.")
                            Picker("Foveated Rendering", selection: $settings.foveatedRendering) {
                                Text("Off").tag(VXFoveatedRendering.off)
                                Text("Low").tag(VXFoveatedRendering.low)
                                Text("Medium").tag(VXFoveatedRendering.medium)
                                Text("High").tag(VXFoveatedRendering.high)
                            }.pickerStyle(.segmented)
                            note("The game draws the middle of the picture at full sharpness and the edge with fewer pixels, which makes it run more smoothly. The stronger, the more you may notice a soft edge when you look sideways. Off by default. Next launch.")
                            Toggle("Sharpening off", isOn: Binding(get: { settings.sharpen == nil }, set: { settings.sharpen = $0 ? nil : 0.35 }))
                            if let v = settings.sharpen {
                                HStack {
                                    Text("Sharpening")
                                    Slider(value: Binding(get: { v }, set: { settings.sharpen = $0 }), in: VXSettings.unitRange, step: 0.05)
                                    Text(String(format: "%.2f", v)).font(.system(.body, design: .monospaced)).frame(width: 70)
                                }
                            }
                            note("A light sharpening pass on the final picture. Off by default; about 0.35 is a start. Next launch.")
                            HStack {
                                Text("Base resolution per eye")
                                Spacer()
                                Picker("Base resolution per eye", selection: $settings.baseResolution) {
                                    ForEach(VXSettings.baseResolutions, id: \.self) { v in
                                        Text(v == 0 ? "Standard" : "\(v)").tag(v)
                                    }
                                }.labelsHidden()
                            }
                            note("The width in pixels of the picture each eye is drawn for; Resolution above is a share of it, and MetalFX enlarges to it. Standard is the display's own picture, or \(VXSettings.baseResolutionStandard) with the high-resolution display. Higher is sharper and costs graphics time: the game draws about as many more pixels as the number grows, squared. Next launch.")
                            Toggle("High-resolution display", isOn: $settings.foveation)
                            note("On, the finished picture is handed to the headset foveated: at the display's full sharpness where you look, coarser towards the edge. Off, the default, the headset takes a plain picture at the system's own quality, as before. This is how the picture reaches the display, not what the game draws. Turn it off again if the picture looks warped or the game does not start. Next launch.")
                            Picker("Display quality", selection: Binding(get: { settings.displayQuality }, set: { settings.displayQuality = $0 })) {
                                Text("High").tag(1.0)
                                Text("Medium").tag(0.8)
                                Text("Low").tag(0.65)
                            }.pickerStyle(.segmented).disabled(!settings.foveation)
                            note("Display quality: how finely the finished picture is drawn into the display. That happens on every display frame, whatever the game's own rate, and costs graphics time. Lower leaves more for the game and is a little softer. It counts with the high-resolution display only; without it the system's own quality is used. Next launch.")
                            Picker("Picture filter", selection: $settings.plainResample) {
                                Text("Sharp").tag(false)
                                Text("Plain").tag(true)
                            }.pickerStyle(.segmented)
                            note("Picture filter: “Sharp”, the default, keeps fine detail steady while you move your head; “Plain” takes a fifth of the samples and saves graphics time, at the price of a slight shimmer on fine detail. Next launch.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Latency") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Latency", selection: $settings.latency) {
                                Text("Smart").tag(VXLatency.smart)
                                Text("Lower latency").tag(VXLatency.lower)
                                Text("Max throughput").tag(VXLatency.throughput)
                            }.pickerStyle(.segmented).labelsHidden()
                            note(settings.latency == .smart
                                 ? "The default. The game starts each frame as the display frees up, so the display stays fed: the most frames a second without older head poses."
                                 : settings.latency == .lower
                                 ? "The game starts a frame only once its previous one is on its way to the display, so the picture is built from a fresher head pose, at fewer game frames a second."
                                 : "The game runs ahead freely: the most game frames a second, but each picture is built from an older head pose.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Your hands") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Show my real hands over the game", isOn: $settings.showHands)
                            note("Off by default: the game draws its own controllers, and your real hands would be a second pair in the same place. Takes effect at once.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Graphics quality") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Graphics quality", selection: $settings.graphics) {
                                Text("Standard").tag(VXGraphics.standard)
                                Text("Low").tag(VXGraphics.low)
                                Text("Medium").tag(VXGraphics.medium)
                                Text("High").tag(VXGraphics.high)
                            }.pickerStyle(.segmented).labelsHidden()
                            note(settings.graphics == .standard
                                 ? "The default: the balanced values this app starts the game with. Nothing more is written."
                                 : settings.graphics == .low
                                 ? "The game's own “Low”: shorter shadows, distant objects and trees in their simpler forms sooner, less grass, no tree animation. The one to try when the game stutters."
                                 : settings.graphics == .medium
                                 ? "The game's own “Medium”: full detail in the distance, shadows to a middle distance."
                                 : "The game's own “High”: finer shadows than Low, shadows on trees, more grass. The heaviest of the three.")
                            note("Low, Medium and High write the scene-detail values of the game's own presets over its settings; the size of the picture stays as set under Picture. Applies the next time you start.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Turning") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Turning", selection: $settings.turn) {
                                Text("Game default").tag(VXTurn.game)
                                Text("Snap").tag(VXTurn.snap)
                                Text("Smooth").tag(VXTurn.smooth)
                            }.pickerStyle(.segmented).labelsHidden()
                            note(settings.turn == .game
                                 ? "Leaves turning as the game has it."
                                 : settings.turn == .snap
                                 ? "Flicking the right stick turns you in steps."
                                 : "Holding the right stick turns you smoothly. Some people find this uncomfortable.")
                            Toggle("Snap angle: game default", isOn: Binding(get: { settings.snapAngle == nil }, set: { settings.snapAngle = $0 ? nil : VXSettings.snapAngleBuiltIn }))
                            if let a = settings.snapAngle {
                                HStack {
                                    Slider(value: Binding(get: { a }, set: { settings.snapAngle = $0 }), in: VXSettings.snapAngleRange, step: 5)
                                    Text(String(format: "%.0f°", a)).font(.system(.body, design: .monospaced)).frame(width: 70)
                                }
                            }
                            Toggle("Turn speed: game default", isOn: Binding(get: { settings.turnSpeed == nil }, set: { settings.turnSpeed = $0 ? nil : VXSettings.turnSpeedBuiltIn }))
                            if let v = settings.turnSpeed {
                                HStack {
                                    Slider(value: Binding(get: { v }, set: { settings.turnSpeed = $0 }), in: VXSettings.turnSpeedRange, step: 0.1)
                                    Text(String(format: "%.1f", v)).font(.system(.body, design: .monospaced)).frame(width: 70)
                                }
                            }
                            note("Game default writes nothing: the game keeps its own choice. The snap angle is for Snap turning and the speed for Smooth turning. Applies the next time you start.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Movement") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Movement", selection: $settings.move) {
                                Text("Game default").tag(VXMove.game)
                                Text("Teleport").tag(VXMove.teleport)
                                Text("Walk").tag(VXMove.walk)
                            }.pickerStyle(.segmented).labelsHidden()
                            note(settings.move == .game
                                 ? "Leaves movement as the game has it."
                                 : settings.move == .teleport
                                 ? "Push the left stick forward to aim and release to jump there."
                                 : "The left stick walks you around directly.")
                            note("Applies the next time you start.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Game language") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Game language", selection: $settings.gameLanguage) {
                                ForEach([VXGameLanguage.auto] + VXGameLanguage.named) { Text($0.ownName).tag($0) }
                            }.pickerStyle(.menu).labelsHidden()
                            note(settings.gameLanguageNote)
                            note("Applies the next time you start.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(VXIniSetting.Group.allCases, id: \.self) { g in
                        GroupBox(g.rawValue) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(VXIniSetting.all.filter { $0.group == g }) { item in iniRow(item) }
                                note(g == .body || g == .teleport
                                     ? "Game default writes nothing: the game keeps its own value. Number ranges are cautious bounds, not the game's. Applies the next time you start."
                                     : "Game default writes nothing: the game keeps its own value. Applies the next time you start.")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GroupBox("Mods") {
                        VXModsList()
                    }
                    GroupBox("Start") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Start automatically", isOn: $settings.startAutomatically)
                            note("Off: this window waits for Start. On: the game starts \(VXSettings.autoStartDelay) seconds after the app opens, and this window stays open until then so you can cancel or change settings.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Label(launcher.started ? "The game is running: resolution and upscaling apply the next time you open the app."
                                           : "Resolution and upscaling apply when you press Start; latency, hand visibility and controller alignment apply at once.",
                          systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("Advanced", isExpanded: $advancedOpen) {
                        VStack(alignment: .leading, spacing: 14) { advanced }.padding(.top, 10)
                    }
                }
                .padding(.horizontal, 40).padding(.vertical, 24)
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
        }
    }

    @ViewBuilder private var advanced: some View {
        GroupBox("Controller alignment") {
            VStack(alignment: .leading, spacing: 10) {
                // The values land in Documents/vxrt_sense.txt, which the running game re-reads once a second.
                senseSlider("Pitch", $sense.pitch, -45...45, 0.5, "°")
                senseSlider("Yaw", $sense.yaw, -45...45, 0.5, "°")
                senseSlider("Roll", $sense.roll, -45...45, 0.5, "°")
                senseSlider("Forward", Binding(get: { -sense.pos.z * 100 }, set: { sense.pos.z = -$0 / 100 }), -12...12, 0.5, " cm")
                senseSlider("Up", Binding(get: { sense.pos.y * 100 }, set: { sense.pos.y = $0 / 100 }), -12...12, 0.5, " cm")
                senseSlider("Right", Binding(get: { sense.pos.x * 100 }, set: { sense.pos.x = $0 / 100 }), -12...12, 0.5, " cm")
                HStack {
                    Button("Reset") { sense = VXSenseValues(); VXSenseValues.reset() }
                    Text(sense.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                note("Rotates and moves the controller the game draws against your Sense controller, about the controller's own axes. Stored in Documents/vxrt_sense.txt; applies to a running game within a second.")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Head prediction") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Automatic", isOn: Binding(get: { settings.predictMs == nil }, set: { settings.predictMs = $0 ? nil : 60 }))
                if let p = settings.predictMs {
                    HStack {
                        Slider(value: Binding(get: { p }, set: { settings.predictMs = $0 }), in: VXSettings.predictRange, step: 5)
                        Text(String(format: "%.0f ms", p)).font(.system(.body, design: .monospaced)).frame(width: 80)
                    }
                }
                note("How far ahead the game's head pose is predicted. Automatic follows the measured delay of the game's pictures (up to 140 ms); a fixed value is for experiments. Applies the next time you start.")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Stage eye height") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Default (1.6 m)", isOn: Binding(get: { settings.stageEyeHeight == nil }, set: { settings.stageEyeHeight = $0 ? nil : 1.6 }))
                if let h = settings.stageEyeHeight {
                    HStack {
                        Slider(value: Binding(get: { h }, set: { settings.stageEyeHeight = $0 }), in: VXSettings.eyeHeightRange, step: 0.05)
                        Text(String(format: "%.2f m", h)).font(.system(.body, design: .monospaced)).frame(width: 80)
                    }
                }
                note("The height of your eyes above the floor the game assumes, which sets where the floor is. Seated play wants a lower value. Applies the next time you start.")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Diagnostics") {
            VStack(alignment: .leading, spacing: 10) {
                let docs = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
                ForEach(["vxrt.log", "host_log.jsonl"], id: \.self) { name in
                    let path = (docs as NSString).appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: path) {
                        ShareLink(item: URL(fileURLWithPath: path)) { Label("Export \(name)", systemImage: "square.and.arrow.up") }
                    } else {
                        Text("\(name): not written yet").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func iniRow(_ item: VXIniSetting) -> some View {
        switch item.kind {
        case .flag:
            HStack {
                Text(item.title)
                Spacer()
                Picker(item.title, selection: Binding(get: { settings.flag(item.id) }, set: { settings.setFlag(item.id, $0) })) {
                    Text("Game default").tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            }
        case .number(let range, let step, let unit):
            VStack(alignment: .leading) {
                Toggle("\(item.title): game default", isOn: Binding(get: { settings.number(item.id) == nil },
                                                                   set: { settings.setNumber(item.id, $0 ? nil : (range.lowerBound + range.upperBound) / 2) }))
                if let v = settings.number(item.id) {
                    HStack {
                        Slider(value: Binding(get: { v }, set: { settings.setNumber(item.id, $0) }), in: range, step: step)
                        Text(String(format: "%g%@", v, unit)).font(.system(.body, design: .monospaced)).frame(width: 70)
                    }
                }
            }
        }
    }

    private func senseSlider(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ step: Float, _ unit: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: step, onEditingChanged: { editing in if !editing { sense.save() } })
            Text(String(format: "%+.1f%@", value.wrappedValue, unit)).font(.system(.body, design: .monospaced)).frame(width: 90)
        }
    }
}
