// VX Runtime's app: the window (the runtime's flat display, main.m's VXRootController: the program starts there) and
// the immersive space the program's swap chain is shown in (VXImmersive.swift). The space opens by itself at launch
// unless the app was started with -present flat (the window then is the only picture: a debug fallback).
import CompositorServices
import QuartzCore
import SwiftUI
import UIKit

@main
struct VXRuntimeApp: App {
    @Environment(\.scenePhase) private var phase
    init() {
        vxrt_jlog("app_init", nil)
        vxrt_boot_fallback()
        // Main-thread heartbeat every 0.5 s: the last one before a system kill says when the app stopped being alive, and
        // the frame counter says whether the compositor loop was still presenting.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let ago = VXImmersiveRenderer.lastFrameUptime > 0 ? CACurrentMediaTime() - VXImmersiveRenderer.lastFrameUptime : -1
            vxrt_jlog("heartbeat", "\"frames\":\(VXImmersiveRenderer.frameCount),\"last_frame_ago_s\":\(String(format: "%.3f", ago)),\"app_state\":\(UIApplication.shared.applicationState.rawValue)")
        }   // (main.m: the program starts without the window if no window has appeared within a few seconds)
    }
    var body: some Scene {
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

        ImmersiveSpace(id: "vr") {
            CompositorLayer(configuration: VXLayerConfiguration()) { layerRenderer in
                VXImmersiveRenderer.start(layerRenderer)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        // Klepton's scene conventions (visionos/Sources/KleptonApp.swift, Immersive.systemOverlays): the Home indicator and
        // hand-gesture affordance do not sit on top of the game's picture. A request, not a guarantee. VXRT_OVERLAYS=1 undoes it.
        .persistentSystemOverlays(ProcessInfo.processInfo.environment["VXRT_OVERLAYS"] == "1" ? .automatic : .hidden)
    }
}

// What backgrounding means for the xrizer immersive app: the end of the process (Klepton's Lifecycle.scenePhaseChanged,
// KleptonApp.swift, adapted). The guest's threads, the ARKit session, the compositor layer and the translated game
// cannot be resumed, so a crown press (the layer invalidated, then the scene inactive) or the system backgrounding
// the app exits, and every launch is a first launch. Only for the xrizer immersive build; VXRT_EXIT_ON_BACKGROUND=0
// keeps the process (a debugging session with the headset off).
enum VXLifecycle {
    nonisolated(unsafe) static var outputEnded = false
    // The compositor layer was invalidated by the system (a pause of the immersive space we did not ask for: device run 6 at 71 s, with no
    // scene change). Returns true when a reopen was scheduled; the reopen budget is five. The xrizer fixture's surface loss is one-way and
    // xrizer aborts the process once it has no surface, so the answer is to bring the space back, not to give up.
    nonisolated(unsafe) static var reopens = 0
    static func layerInvalidated() -> Bool {
#if XRIZER_XROS_FIXTURE
        guard vx_xros_immersive_enabled() != 0, ProcessInfo.processInfo.environment["VXRT_REOPEN"] != "0" else { return false }
        if reopens >= 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                vxrt_jlog("lifecycle_exit", "\"phase\":\"layer_invalidated\",\"reopens\":\(reopens)")
                fflush(nil)
                exit(0)
            }
            return false
        }
        reopens += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { NotificationCenter.default.post(name: .vxReopenImmersive, object: nil) }
        return true
#else
        return false
#endif
    }
    static func scenePhaseChanged(to phase: ScenePhase) {
#if XRIZER_XROS_FIXTURE
        guard vx_xros_immersive_enabled() != 0,
              ProcessInfo.processInfo.environment["VXRT_EXIT_ON_BACKGROUND"] != "0" else { return }
        if (phase == .inactive && outputEnded) || phase == .background {
            vxrt_jlog("lifecycle_exit", "\"phase\":\"\(phase)\",\"output_ended\":\(outputEnded)")
            fflush(nil)
            exit(0)
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
        let colors = capabilities.supportedColorFormats(options: [])
        if colors.contains(.bgra8Unorm_srgb) { configuration.colorFormat = .bgra8Unorm_srgb }
        if capabilities.supportedDepthFormats.contains(.depth32Float) { configuration.depthFormat = .depth32Float }
    }
}

extension Notification.Name { static let vxReopenImmersive = Notification.Name("vxReopenImmersive") }

struct VXRootControllerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { vxrt_make_root_controller() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

struct VXDisplayView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var opened = false
    private static var hideFlatWindow: Bool {
#if XRIZER_XROS_FIXTURE
        return vx_xros_immersive_enabled() != 0 && ProcessInfo.processInfo.environment["VXRT_SHOW_WINDOW"] != "1"
#else
        return false
#endif
    }

    var body: some View {
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
            .onAppear { vxrt_jlog("display_view", nil) }
            // The system ended the compositor layer (VXLifecycle.layerInvalidated): open the immersive space again; the new
            // CompositorLayer closure rebinds the running provider (VXImmersiveRenderer.start).
            .onReceive(NotificationCenter.default.publisher(for: .vxReopenImmersive)) { _ in
                Task {
                    let result = await openImmersiveSpace(id: "vr")
                    let text: String
                    switch result {
                    case .opened: text = "opened"
                    case .userCancelled: text = "cancelled"
                    case .error: text = "error"
                    @unknown default: text = "unknown"
                    }
                    vxrt_jlog("immersive_space", "\"result\":\"\(text)\",\"reopen\":\(VXLifecycle.reopens)")
                }
            }
            .task {
                guard !opened, vxrt_present_vr() != 0 else { return }
                opened = true
                let result = await openImmersiveSpace(id: "vr")
                let text: String
                switch result {
                case .opened: text = "opened"
                case .userCancelled: text = "cancelled"
                case .error: text = "error"
                @unknown default: text = "unknown"
                }
                vxrt_jlog("immersive_space", "\"result\":\"\(text)\"")
                if result == .opened, Self.hideFlatWindow, ProcessInfo.processInfo.environment["VXRT_DISMISS_WINDOW"] == "1" {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    dismissWindow(id: "display")
                    vxrt_jlog("window_dismissed", nil)
                }
            }
    }
}
