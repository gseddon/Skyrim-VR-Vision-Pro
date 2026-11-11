// VX Runtime's app: the window (the runtime's flat display, main.m's VXRootController: the program starts there) and
// the immersive space the program's swap chain is shown in (VXImmersive.swift). The space opens by itself at launch
// unless the app was started with -present flat (the window then is the only picture: a debug fallback).
import CompositorServices
import OSLog
import QuartzCore
import SwiftUI
import UIKit

@main
struct VXRuntimeApp: App {
    @Environment(\.scenePhase) private var phase
    // Hand visibility is a setting (VXSettings, default hidden; VXRT_SHOW_HANDS / KL_HAND_MATTING still win): observed, so the toggle applies live.
    @ObservedObject private var settings = VXSettings.shared
    // The start window gates the program (VXLaunchGate): the display window, whose view starts it, is opened by Start.
    static let gated = VXLaunchGate.enabled(info: Bundle.main.infoDictionary ?? [:], environment: ProcessInfo.processInfo.environment,
                                            defaultLaunch: vxrt_default_launch() != 0)
    init() {
#if XRIZER_XROS_FIXTURE
        VXSettings.latencyHook = { vx_xros_set_gate_mode(Int32($0.gateMode)) }
#endif
        vxrt_jlog("app_init", "\"start_window\":\(Self.gated)")
        if !Self.gated { vxrt_boot_fallback() }
        VXLifecycle.observeApplication()
        VXKeyboardController.install()   // the game's text requests (name entry) open the keyboard window (VXKeyboard.swift)
        _ = VXImmersiveController.shared   // the app-level owner of the immersive space exists before any view
        // Main-thread heartbeat every 0.5 s: the last one before a system kill says when the app stopped being alive, and
        // the frame counter says whether the compositor loop was still presenting.
        var lastCPU = 0.0, lastWall = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            // process CPU over the last beat in % of one core (all threads: the game's workers keep running while its render thread idles in a pause)
            var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
            let cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
            let wall = CACurrentMediaTime()
            let cpuPct = (cpu - lastCPU) / max(wall - lastWall, 0.001) * 100
            lastCPU = cpu; lastWall = wall
            let ago = VXImmersiveRenderer.lastFrameUptime > 0 ? CACurrentMediaTime() - VXImmersiveRenderer.lastFrameUptime : -1
            vxrt_jlog("heartbeat", "\"frames\":\(VXImmersiveRenderer.frameCount),\"last_frame_ago_s\":\(String(format: "%.3f", ago)),\"cpu_pct\":\(String(format: "%.0f", cpuPct)),\"app_state\":\(UIApplication.shared.applicationState.rawValue)")
        }   // (main.m: the program starts without the window if no window has appeared within a few seconds)
    }
    var body: some Scene {
        // The start window (VXStartView.swift): shown at launch in a gated build, suppressed otherwise.
        WindowGroup(id: "start") { VXStartView() }
            .defaultSize(width: 900, height: 640)
            .defaultLaunchBehavior(Self.gated ? .automatic : .suppressed)
            .restorationBehavior(.disabled)

        VXKeyboardScene()   // the text-entry window the game's keyboard requests open (suppressed at launch)

        WindowGroup(id: "display") {
            VXDisplayView()
        }
        .onChange(of: phase) { _, p in
            vxrt_jlog("scene_phase", "\"phase\":\"\(p)\"")
            VXLifecycle.scenePhaseChanged(to: p)
        }
        .windowResizability(.contentSize)
        // Klepton's window arrangement (KleptonApp.swift: .windowStyle(.plain), "drops the system's glass plate"; utility-panel
        // placement): no glass backing for the (hidden) display window.
        .windowStyle(.plain)
        .defaultWindowPlacement { _, _ in WindowPlacement(.utilityPanel) }
        .defaultLaunchBehavior(Self.gated ? .suppressed : .automatic)
        .restorationBehavior(Self.gated ? .disabled : .automatic)

        ImmersiveSpace(id: "vr") {
            CompositorLayer(configuration: VXLayerConfiguration()) { layerRenderer in
                VXImmersiveRenderer.start(layerRenderer)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        // Klepton's scene conventions (visionos/Sources/KleptonApp.swift, Immersive.systemOverlays): the Home indicator and
        // hand-gesture affordance do not sit on top of the game's picture. A request, not a guarantee. VXRT_OVERLAYS=1 undoes it.
        .persistentSystemOverlays((ProcessInfo.processInfo.environment["VXRT_OVERLAYS"] ?? ProcessInfo.processInfo.environment["KL_OVERLAYS"]) == "1" ? .automatic : .hidden)
        // The wearer's real hands and arms are not shown "punched through" the game's picture (the user's choice, 2026-11-10): the same
        // scene modifier Klepton uses (KleptonApp.swift .upperLimbVisibility). VXRT_SHOW_HANDS=1 shows them; a Klepton frontend setting later
        // (default: hidden).
        .upperLimbVisibility(settings.handsVisible ? .visible : .hidden)
    }
}

// What backgrounding means for the xrizer immersive app: the end of the process (Klepton's Lifecycle.scenePhaseChanged,
// KleptonApp.swift, adapted). The guest's threads, the ARKit session, the compositor layer and the translated game
// cannot be resumed, so a crown press (the layer invalidated, then the scene inactive) or the system backgrounding
// the app exits, and every launch is a first launch. Only for the xrizer immersive build; VXRT_EXIT_ON_BACKGROUND=0
// keeps the process (a debugging session with the headset off).
// The app-level owner of Skyrim's immersive space (the views only reflect `needsResume` and hand over the scene's open action). Opening happens
// ONCE per launch from here, whichever view instance appears first or how often SwiftUI rebuilds the window content (device log 2026-11-10 20:52:
// two display_view and two window events 20 ms apart; g_booted in main.m already keeps the program to one start). Single-flight and the retries
// live in VXLifecycle.openSpace; each attempt uses the NEWEST action handed over, since the first instance's action can fail while its view is
// being replaced. `needsResume` drives the Resume window.
final class VXImmersiveController: ObservableObject {
    static let shared = VXImmersiveController()
    @Published var needsResume = false
    nonisolated(unsafe) private var opener: (() async -> OpenImmersiveSpaceAction.Result)?
    nonisolated(unsafe) private var afterLaunchOpened: (() -> Void)?
    nonisolated(unsafe) private var launched = false
    nonisolated(unsafe) private(set) var attachCount = 0
    init() {
        NotificationCenter.default.addObserver(forName: .vxReopenImmersive, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.reopen() }
        }
    }
    // Every confirmed-open of the space (launch, reopen, Resume tap) also tells the start window to go away: it must not sit in front of the game.
    func setNeedsResume(_ v: Bool) { if !v { DispatchQueue.main.async { NotificationCenter.default.post(name: .vxSpaceOpened, object: nil) } }
        DispatchQueue.main.async { if self.needsResume != v { self.needsResume = v; vxrt_jlog("resume_ui", "\"shown\":\(v)") } } }
    // Called by every display view instance as it appears; only the first one starts the launch open.
    @MainActor func attach(instance: Int, open: @escaping () async -> OpenImmersiveSpaceAction.Result, afterOpened: @escaping () -> Void) {
        attachCount += 1
        opener = open; afterLaunchOpened = afterOpened
        vxrt_jlog("controller_attach", "\"instance\":\(instance),\"attach\":\(attachCount),\"launched\":\(launched),\"app_state\":\(UIApplication.shared.applicationState.rawValue)")
        guard !launched, vxrt_present_vr() != 0 else { return }
        launched = true
        Task {
            vxrt_jlog("immersive_open_request", "\"app_state\":\(UIApplication.shared.applicationState.rawValue)")
            if await VXLifecycle.openSpace(attempts: 3, watchdog: 30, tag: "launch") { self.afterLaunchOpened?() }
        }
    }
    func reopen() async {
        vxrt_jlog("immersive_reopen_request", "\"app_state\":\(await UIApplication.shared.applicationState.rawValue),\"reopen\":\(VXLifecycle.reopens)")
        _ = await VXLifecycle.openSpace(attempts: 3, watchdog: 10, tag: "reopen")
    }
    func openNow() async -> OpenImmersiveSpaceAction.Result { guard let o = opener else { return .error }; return await o() }
}

enum VXLifecycle {
    nonisolated(unsafe) static var outputEnded = false
    // The compositor layer was invalidated by the system (a pause of the immersive space we did not ask for: device run 6 at 71 s, with no
    // scene change). Returns true when a reopen was scheduled; the reopen budget is five. The xrizer fixture's surface loss is one-way and
    // xrizer aborts the process once it has no surface, so the answer is to bring the space back, not to give up.
    nonisolated(unsafe) static var reopens = 0
    static func layerInvalidated() -> Bool {
        spaceOpen = false
        dumpSystemLog("layer_invalidated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { dumpSystemLog("layer_invalidated+2s", seconds: 4) }
#if XRIZER_XROS_FIXTURE
        guard vx_xros_immersive_enabled() != 0, ProcessInfo.processInfo.environment["VXRT_REOPEN"] != "0" else { return false }
        // Pause and resume, not exit (the old budget of five reopens ended the process; c41b5f1 adapted that from Klepton). The game, the
        // provider and ARKit stay alive: with no layer, no sample reaches the provider and xrWaitFrame times out every 2 s (the game idles at 0.5
        // fps, no spin). The system takes the space away (headset off, crown, a notification); asking for it back is answered only once the
        // app is active again (device run 14: 172 s), so ask now with a growing delay, and show the Resume window meanwhile.
        reopens += 1
        invalidatedAt = CACurrentMediaTime()
        // The Crown ends the app (the wearer's wish, 2026-11-10): the layer is invalidated AND the app leaves (resigns active) within a short
        // window of it, in either order. A headset off only pauses the layer (device L2-L4: resign_active, background, vr_pause, no invalidation)
        // and keeps the pause/resume behaviour. The Resume panel is no longer shown here: only a failed open while active shows it.
        // Device run4 (2026-11-11 00:49): the FIRST Crown press invalidates the layer while the app is still ACTIVE (layer_gone active:true,
        // 144.48 s); the app does not resign until 2.3 s later, so the old "invalidated, then left within 1.5 s" rule saw nothing and the 0.7 s
        // reopen put the game back (the "paused, Resume?" the wearer saw). The system, not us, invalidating the layer is the Crown; a headset
        // off only pauses it (.paused, never .invalidated). So an invalidation quits at once, whether or not the app has left yet.
        // crownQuit is a no-op while the keyboard window is open (logged), and then the reopen below carries on as before.
        if crownQuitEnabled { crownQuit(appIsActive() ? "invalidated_while_active" : "invalidated_while_inactive") }
        let delay = min(0.7 * Double(reopens), 5)
        // The layer is gone: if the app is already leaving (Crown, doff), that is the signature of a Crown press; do not fight it.
        let activeNow = appIsActive()
        vxrt_jlog("layer_gone", "\"active\":\(activeNow),\"reopen\":\(reopens)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if appIsActive() { NotificationCenter.default.post(name: .vxReopenImmersive, object: nil) }
            else { suppressReopen("layer_invalidated") }
        }
        return true
#else
        return false
#endif
    }
    // Launch 2026-11-10 19:11 (metalfx arm A): the layer was invalidated 8.5 s after launch, UIApplication went to background 0.5 s later, and
    // SwiftUI's scenePhase never changed (the hidden WindowGroup stays "active"), so neither lifecycle_exit nor the reopen's result was ever
    // logged: a live process with a frozen game, 31 s later suspended by the system. These closes that gap: UIApplication's own state is
    // logged; coming back to active reopens a closed space (with retries); an open that is not answered in time is logged. Nothing here quits the
    // app by default (Control Center, a notification or another window must not cost the wearer the game): VXRT_BG_EXIT_S=<seconds> (test
    // sweeps only) exits after that long in the background or after an unanswered open, so a dead arm ends quickly.
    nonisolated(unsafe) static var spaceOpen = false
    nonisolated(unsafe) static var reopenPending = false
    // SwiftUI builds the WindowGroup's content twice at launch (device log 2026-11-10 20:52: two display_view and two window events 20 ms
    // apart; main.m's g_booted keeps the program to one start), so each instance's .task asked for the space. One open at a time: a second
    // caller while one is in flight (or the space is already open) does not call openImmersiveSpace again.
    nonisolated(unsafe) static var openInFlight = false
    // A Crown press (or a notification, the headset coming off) invalidates the layer and sends the app to Home. Anything that then calls
    // openImmersiveSpace / openWindow brings the app straight back to the front (the mask build 2f62975: "Home shows briefly, then Skyrim comes
    // straight back": layerInvalidated() scheduled a reopen 0.7 s later whatever the app state, and openSpace retried every second). Rule: no open
    // while the app is not active; the open that was wanted is remembered (`reopenWanted`) and done when the wearer brings the app back
    // (didBecomeActive), or by an explicit tap on Resume. A real launch's first open is exempt.
    nonisolated(unsafe) static var reopenWanted = false
    nonisolated(unsafe) static var invalidatedAt: CFTimeInterval = 0
    nonisolated(unsafe) static var resignedAt: CFTimeInterval = 0
    nonisolated(unsafe) static var quitting = false
    nonisolated(unsafe) static var pausedAt: CFTimeInterval = 0   // last time the layer went .paused (the loop sets it): a doff pauses first, a Crown press does not
    // A keyboard window (VXKeyboard.swift) is open for the game's text request. The system keyboard and a second window may take focus from
    // the display window; that is not a Crown press, so no crown_quit while it is open (the signals are still logged).
    nonisolated(unsafe) static var keyboardOpen = false
    static let crownWindow = 1.5   // s: invalidation and leaving the app this close together (either order) are a Crown press
    static var crownQuitEnabled: Bool { ProcessInfo.processInfo.environment["VXRT_CROWN_QUIT"] != "0" }
    // Crown: quit cleanly. Logs which signal fired and the timings behind it (the next device run shows whether the rule separates a Crown press
    // from a headset off), flushes the logs, and exits 0.
    static func crownQuit(_ signal: String) {
        if quitting { return }
        if keyboardOpen { vxrt_jlog("crown_quit_suppressed", "\"signal\":\"\(signal)\",\"why\":\"keyboard_open\""); return }
        quitting = true
        let now = CACurrentMediaTime()
        vxrt_jlog("crown_quit", "\"signal\":\"\(signal)\",\"since_invalidated_s\":\(invalidatedAt > 0 ? String(format: "%.3f", now - invalidatedAt) : "null"),\"since_pause_s\":\(pausedAt > 0 ? String(format: "%.3f", now - pausedAt) : "null"),\"since_resign_s\":\(resignedAt > 0 ? String(format: "%.3f", now - resignedAt) : "null"),\"phase\":\"\(scenePhaseNow)\",\"app_active\":\(appActive),\"frames\":\(VXImmersiveRenderer.frameCount)")
        exitNow("crown_quit")
    }
    nonisolated(unsafe) static var scenePhaseNow: ScenePhase = .active
    // Cached from UIApplication's notifications (no main-thread hop: callers include the compositor thread and main itself).
    nonisolated(unsafe) static var appActive = false
    static func appIsActive() -> Bool { appActive && scenePhaseNow == .active }
    static func suppressReopen(_ why: String, tag: String = "") {
        reopenWanted = true
        vxrt_jlog("reopen_suppressed", "\"why\":\"\(why)\",\"tag\":\"\(tag)\",\"app_active\":\(appActive),\"phase\":\"\(scenePhaseNow)\"")
    }
    nonisolated(unsafe) static var backgroundExit: DispatchWorkItem?
    static var testExitSeconds: Double? { ProcessInfo.processInfo.environment["VXRT_BG_EXIT_S"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } }
    static func exitNow(_ reason: String, _ extra: String = "") {
        dumpSystemLog("exit_" + reason, seconds: 20, waitUpTo: 1.5)
        vxrt_jlog("lifecycle_exit", "\"phase\":\"\(reason)\",\"output_ended\":\(outputEnded),\"frames\":\(VXImmersiveRenderer.frameCount)\(extra)")
        fflush(nil)
        exit(0)
    }
    // The system's own words about why: this process's unified-log entries (CompositorServices, FrontBoard/RunningBoard client-side messages,
    // UIKit scene lifecycle) from the last `seconds`, at notice level or above, into the host log as `syslog` events. Process-scoped, so it
    // needs no entitlement and no device file service. Called when the layer is invalidated, when the app backgrounds and 2 s after each.
    static func dumpSystemLog(_ why: String, seconds: Double = 20, waitUpTo: Double = 0) {
        let done = DispatchSemaphore(value: 0)
        defer { if waitUpTo > 0 { _ = done.wait(timeout: .now() + waitUpTo) } }
        DispatchQueue.global(qos: .utility).async {
            defer { done.signal() }
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { vxrt_jlog("syslog", "\"why\":\"\(why)\",\"error\":\"no store\""); return }
            let position = store.position(date: Date().addingTimeInterval(-seconds))
            guard let entries = try? store.getEntries(at: position) else { return }
            // The store ignores the start position for a process-scoped read (the first dump held launch-time entries): filter by date, and keep
            // the LAST 150 lines, not the first.
            let cutoff = Date().addingTimeInterval(-seconds)
            var kept: [OSLogEntryLog] = []
            for case let e as OSLogEntryLog in entries where e.date >= cutoff && e.level.rawValue >= OSLogEntryLog.Level.notice.rawValue {
                let sub = e.subsystem
                guard sub.contains("CompositorServices") || sub.contains("FrontBoard") || sub.contains("RunningBoard") || sub.contains("UIKit") || sub.contains("SwiftUI") || sub.contains("backboard") || sub.contains("SpringBoard") || sub.contains("RealityKit") || sub.contains("ARKit") || sub.contains("MRUI") || sub.contains("com.apple.xr") || sub.isEmpty else { continue }
                if e.composedMessage.hasPrefix("Realizing settings extension") || e.composedMessage.hasPrefix("Ingesting properties") { continue }
                kept.append(e)
            }
            var n = 0
            for e in kept.suffix(150) {
                let sub = e.subsystem
                let msg = e.composedMessage.prefix(300).map { c -> String in
                    switch c { case "\"": return "\\\""; case "\\": return "\\\\"; case "\n", "\r", "\t": return " "; default: return String(c) } }.joined()
                vxrt_jlog("syslog", "\"why\":\"\(why)\",\"at\":\(String(format: "%.3f", e.date.timeIntervalSince1970)),\"sub\":\"\(sub)\",\"cat\":\"\(e.category)\",\"msg\":\"\(msg)\"")
                n += 1
            }
            vxrt_jlog("syslog_done", "\"why\":\"\(why)\",\"lines\":\(n)")
        }
    }
    static func observeApplication() {
        let nc = NotificationCenter.default
        func state() -> String { "\"app_state\":\(UIApplication.shared.applicationState.rawValue),\"frames\":\(VXImmersiveRenderer.frameCount),\"space_open\":\(spaceOpen),\"reopen_pending\":\(reopenPending)" }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in appActive = false; resignedAt = CACurrentMediaTime(); vxrt_jlog("app_resign_active", state());
            if crownQuitEnabled, invalidatedAt > 0, CACurrentMediaTime() - invalidatedAt < crownWindow { crownQuit("left_after_invalidated") }
            dumpSystemLog("resign_active", seconds: 10) }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            appActive = true
            vxrt_jlog("app_become_active", state())
            backgroundExit?.cancel(); backgroundExit = nil
            // The space was closed (layer invalidated, or never opened) while we were away: bring it back now that the app is active.
            if !spaceOpen && !reopenPending && (VXImmersiveRenderer.frameCount > 0 || reopenWanted) {
                vxrt_jlog("reopen_on_active", "\"wanted\":\(reopenWanted)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if appIsActive() { reopenWanted = false; nc.post(name: .vxReopenImmersive, object: nil) } else { suppressReopen("not_active_after_become_active") }
                }
            }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            appActive = false
            vxrt_jlog("app_background", state())
            vxrt_jlog("crown_bg", "\"space_open\":\(spaceOpen),\"frames\":\(VXImmersiveRenderer.frameCount)")
            dumpSystemLog("app_background")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { dumpSystemLog("app_background+2s", seconds: 4) }
            guard let secs = testExitSeconds else { return }
            let work = DispatchWorkItem { if UIApplication.shared.applicationState == .background { exitNow("app_background_test_exit") } }
            backgroundExit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: work)
        }
    }
    // Opens the immersive space, retrying a refused open (.error / .userCancelled) up to `attempts` times a second apart while the app is
    // not backgrounded. Every attempt logs its result and the app state. `watchdog` seconds without ever opening ends the run with a reason.
    static func openSpace(attempts: Int, watchdog: Double, tag: String) async -> Bool {
        // The first instance's open can fail because its view is being replaced (device log: request 1 "error" at +60 ms, request 2 "opened"
        // at +130 ms), so a late caller waits for the one in flight and opens itself only if the space is still closed.
        if openInFlight {
            vxrt_jlog("immersive_open_waiting", "\"tag\":\"\(tag)\"")
            var waited = 0
            while openInFlight && waited < 100 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        }
        if spaceOpen { vxrt_jlog("immersive_open_skipped", "\"tag\":\"\(tag)\",\"space_open\":true"); VXImmersiveController.shared.setNeedsResume(false); return true }
        reopenPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdog) {
            guard reopenPending else { return }
            vxrt_jlog("immersive_open_timeout", "\"tag\":\"\(tag)\",\"app_state\":\(UIApplication.shared.applicationState.rawValue),\"seconds\":\(watchdog)")
            reopenPending = false   // the open may still answer later; a return to active may ask again
            if testExitSeconds != nil { exitNow("immersive_open_timeout_\(tag)") }
        }
        for attempt in 1...max(1, attempts) {
            if spaceOpen { reopenPending = false; return true }
            // Not while the app is leaving or away (the first launch attempt is exempt: the app is coming to the front by itself).
            if !(tag == "launch" && attempt == 1) && !appIsActive() { reopenPending = false; suppressReopen("not_active", tag: tag); return false }
            openInFlight = true
            let result = await VXImmersiveController.shared.openNow()
            openInFlight = false
            let text: String
            switch result {
            case .opened: text = "opened"
            case .userCancelled: text = "cancelled"
            case .error: text = "error"
            @unknown default: text = "unknown"
            }
            vxrt_jlog("immersive_space", "\"result\":\"\(text)\",\"tag\":\"\(tag)\",\"attempt\":\(attempt),\"reopen\":\(reopens),\"app_state\":\(UIApplication.shared.applicationState.rawValue)")
            if result == .opened { spaceOpen = true; reopenPending = false; VXImmersiveController.shared.setNeedsResume(false); return true }
            if spaceOpen { reopenPending = false; VXImmersiveController.shared.setNeedsResume(false); return true }
            if attempt < attempts { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        reopenPending = false
        VXImmersiveController.shared.setNeedsResume(true)
        return false
    }
    // Backgrounding pauses; it no longer ends the process. VXRT_BG_EXIT_S=<s> (observeApplication) is the test-sweep exit, and
    // VXRT_EXIT_ON_BACKGROUND=1 restores the old immediate exit (Klepton's policy).
    static func scenePhaseChanged(to phase: ScenePhase) {
        scenePhaseNow = phase
        if phase != .active { vxrt_jlog("crown_bg", "\"phase\":\"\(phase)\",\"space_open\":\(spaceOpen),\"frames\":\(VXImmersiveRenderer.frameCount)") }
#if XRIZER_XROS_FIXTURE
        guard vx_xros_immersive_enabled() != 0 else { return }
        // A background / inactive scene is a PAUSE: the compositor layer pauses and resumes by itself when the app is active again (device L3,
        // 2026-11-10 21:04). Showing the Resume window here (4d66205) put a flat window in front of the resumed game, and its button was a
        // no-op because the space was still open. Resume is shown only when the space is really gone (layerInvalidated, a failed open).
        if phase == .background || (phase == .inactive && outputEnded) {
            if ProcessInfo.processInfo.environment["VXRT_EXIT_ON_BACKGROUND"] == "1" { exitNow("scene_\(phase)") }
        }
#endif
    }
}

struct VXLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        // One texture per eye (the warp writes each eye's whole texture), no foveation for now (the warp would have to
        // draw through the rasterization rate map: VISIONOS_PORT.md), depth for the compositor's late reprojection.
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : (layouts.first ?? .dedicated)
        configuration.isFoveationEnabled = false
        // VXRT_RENDER_QUALITY=0..1 (unset: the system default, as before): the drawable's resolution (visionOS 26 CompositorServices render quality; it sets the
        // size of the textures the compositor gives us, so the game's size, VXRT_RENDER_SCALE of it, moves too). Logged: default, max and the value used.
        if #available(visionOS 26.0, *), let e = ProcessInfo.processInfo.environment["VXRT_RENDER_QUALITY"], let q = Float(e), q >= 0, q <= 1 {
            configuration.maxRenderQuality = .init(q)
            vxrt_jlog("render_quality_config", "\"default\":\(capabilities.defaultRenderQuality),\"max\":\(q)")
        }
        let colors = capabilities.supportedColorFormats(options: [])
        if colors.contains(.bgra8Unorm_srgb) { configuration.colorFormat = .bgra8Unorm_srgb }
        if capabilities.supportedDepthFormats.contains(.depth32Float) { configuration.depthFormat = .depth32Float }
    }
}

extension Notification.Name { static let vxSpaceOpened = Notification.Name("vxSpaceOpened"); static let vxReopenImmersive = Notification.Name("vxReopenImmersive") }

struct VXRootControllerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { vxrt_make_root_controller() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

struct VXDisplayView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var space = VXImmersiveController.shared
    // Which instance this is (SwiftUI rebuilt the content at launch: see VXImmersiveController).
    private let instance: Int = { VXDisplayView.counter += 1; vxrt_jlog("display_view_init", "\"instance\":\(VXDisplayView.counter)"); return VXDisplayView.counter }()
    nonisolated(unsafe) static var counter = 0
    private static var hideFlatWindow: Bool {
#if XRIZER_XROS_FIXTURE
        return vx_xros_immersive_enabled() != 0 && ProcessInfo.processInfo.environment["VXRT_SHOW_WINDOW"] != "1"
#else
        return false
#endif
    }

    var body: some View {
        ZStack {
            display
            if space.needsResume && Self.hideFlatWindow {
                // The immersive space was taken away (headset off, crown, a notification) or could not be opened: the game is paused, not gone.
                VStack(spacing: 16) {
                    Text("Skyrim VR is paused").font(.title2)
                    Button("Resume") {
                        Task {
                            // this view's own, live action (not one captured from a replaced scene), and its result is logged
                            let result = await openImmersiveSpace(id: "vr")
                            vxrt_jlog("resume_tap", "\"result\":\"\(result)\",\"app_state\":\(UIApplication.shared.applicationState.rawValue)")
                            if case .opened = result { VXLifecycle.spaceOpen = true; VXImmersiveController.shared.setNeedsResume(false) }
                        }
                    }
                }
                .padding(32)
                .glassBackgroundEffect()
            }
        }
        .vxKeyboardOpener()   // this view lives as long as the game (it hosts the swap chain's view), so it can open the keyboard window
    }

    private var display: some View {
        VXRootControllerView()
            // xrizer immersive: the game's pairs are in the immersive space, and the runtime's flat display of the game's window
            // (one eye, the desktop back buffer: what device run 5 showed) must not sit in front of them. The view stays in the
            // hierarchy, small and invisible, because the game's swap chain presents into it (a detached layer could stall the
            // game's present). VXRT_SHOW_WINDOW=1 brings it back.
            .frame(width: Self.hideFlatWindow ? 160 : 1280, height: Self.hideFlatWindow ? 90 : 720)
            .opacity(Self.hideFlatWindow ? 0 : 1)
            .allowsHitTesting(!Self.hideFlatWindow)
            // Device runs 9 to 13: the hidden window was still faintly visible. No glass plate behind it, and no system chrome (the grabber,
            // the close button) on it; VXRT_DISMISS_WINDOW=1 additionally closes the window once the space is open (Klepton's
            // dismissWindow()). Closing detaches the swap chain's host view: untested whether the game keeps presenting, so a lever.
            .glassBackgroundEffect(displayMode: Self.hideFlatWindow ? .never : .always)
            .persistentSystemOverlays(Self.hideFlatWindow ? .hidden : .automatic)
            .onAppear {
                vxrt_jlog("display_view", "\"instance\":\(instance)")
                VXImmersiveController.shared.attach(instance: instance, open: { await openImmersiveSpace(id: "vr") }, afterOpened: {
                    guard Self.hideFlatWindow, ProcessInfo.processInfo.environment["VXRT_DISMISS_WINDOW"] == "1" else { return }
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); dismissWindow(id: "display"); vxrt_jlog("window_dismissed", nil) }
                })
            }
    }
}
