// The start window and the settings page. A Klepton-style front (Start, Settings, status, version stamp), shown instead of booting straight into
// the game when the build asks for it (Info.plist VXStartWindow, VXLaunchGate). Start applies the settings to the environment and only then opens
// the display window, whose view starts the program (main.m vxrt_boot), so everything the runtime reads at first use sees the chosen values.
//
// Layout and wording adapted from Klepton (MIT, Copyright (c) 2026 Max Thomas; fork https://github.com/myMartek/Klepton at
// a7bad301c10b03e7d615ae8d51033146c373bcb5; license text third_party/klepton_openxr/LICENSE), visionos/Sources/KleptonApp.swift: BootView.startFront
// (:1132-1300: title, large Start, Settings, status line, version stamp in the corner), BootView.settingsPage (:1342-1415: NavigationStack, GroupBox
// sections, grey callout explanations, an Advanced DisclosureGroup, Done), PlayerSettingsView (:719-840: Picture, Your hands, "Changes to the picture
// apply the next time you start the game"), KleptonTuning.swift TuningView (:106) for the alignment sliders. Reimplemented, English only; the Klepton
// runtime seams (kl_*) are not used. Branding is text only: no game art.
import SwiftUI

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
        vxrt_jlog("settings_applied", "\"set\":\"\(r.set.joined(separator: " "))\",\"kept\":\"\(r.kept.joined(separator: " "))\"")
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
        VStack(spacing: 22) {
            Spacer()
            Text(Self.title).font(.extraLargeTitle.bold())
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
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if let stamp = Self.versionStamp {
                Text(stamp).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize().padding(.trailing, 48).padding(.bottom, 20)
            }
        }
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
                            note("The size the game draws each eye at, as a share of the display's. Lower is smoother on a busy scene; higher is sharper. 55% with MetalFX is the default.")
                            Picker("Upscaling", selection: $settings.upscale) {
                                Text("MetalFX").tag(VXUpscale.metalfx)
                                Text("Bilinear").tag(VXUpscale.bilinear)
                            }.pickerStyle(.segmented)
                            note(settings.upscale == .metalfx
                                 ? "Apple's MetalFX spatial upscaler brings the game's picture up to the display's size: sharper than plain scaling."
                                 : "The display's own sampler stretches the picture: softer, with no extra work.")
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

    private func senseSlider(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ step: Float, _ unit: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: step, onEditingChanged: { editing in if !editing { sense.save() } })
            Text(String(format: "%+.1f%@", value.wrappedValue, unit)).font(.system(.body, design: .monospaced)).frame(width: 90)
        }
    }
}
