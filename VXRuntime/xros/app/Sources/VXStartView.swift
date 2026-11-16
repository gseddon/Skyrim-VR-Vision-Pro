// The start window and the settings page. A Klepton-style front (Start, Settings, status, version stamp), shown instead of booting straight into
// the game when the build asks for it (Info.plist VXStartWindow, VXLaunchGate). Start applies the settings to the environment and only then opens
// the display window, whose view starts the program (main.m vxrt_boot), so everything the runtime reads at first use sees the chosen values.
//
// Layout and wording adapted from Klepton (MIT, Copyright (c) 2026 Max Thomas; fork https://github.com/myMartek/Klepton at
// a7bad301c10b03e7d615ae8d51033146c373bcb5; license text third_party/klepton_openxr/LICENSE), visionos/Sources/KleptonApp.swift: BootView.startFront
// (:1132-1300: title, large Start, Settings, status line, version stamp in the corner), BootView.settingsPage (:1342-1415: NavigationStack, GroupBox
// sections, grey callout explanations, an Advanced DisclosureGroup, Done), PlayerSettingsView (:719-840: Picture, Your hands, "Changes to the picture
// apply the next time you start the game"), KleptonTuning.swift TuningView (:106) for the alignment sliders. Reimplemented, in English and German (vxT); the Klepton
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
        VXStatsPanel.shared.setVisible(VXSettings.shared.statsPanel, why: "setting")
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
        Group { if showSettings { VXSettingsWindow(done: { showSettings = false }) } else { front } }
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

// The settings window is VXSettingsWindow.swift: pages, presets, and what each setting does on the right.
