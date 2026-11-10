// Text entry for the game's keyboard requests. Skyrim VR asks for text (the character's name in the race menu) with
// IVROverlay::ShowKeyboardForOverlay; the runtime's OpenVR bridge (src/xrizer_guest_bridge.c) answers success at once and calls the
// hook installed here, which opens a small window with a focused text field: visionOS then raises its system keyboard for it. Done
// (the keyboard's Done/Return key or the button) hands the text back, Cancel (or closing the window) keeps what the game offered; the
// bridge turns that into VREvent_KeyboardDone/KeyboardClosed for the game and GetKeyboardText returns the text.
//
// Wiring (three one-line additions to files that differ between branches):
//   VXRuntimeHost-Bridging-Header.h   #include "xrizer_guest_bridge.h"
//   VXApp.swift  (App.init)           VXKeyboardController.install()
//   VXApp.swift  (App.body)           VXKeyboardScene()
//   an always-present view (the display window's content): .vxKeyboardOpener()
// The system keyboard is driven by the wearer's hands (gaze + pinch, or poking the keys); the game's controllers do not drive it.
import SwiftUI
import UIKit

@MainActor
final class VXKeyboardController: ObservableObject {
    static let shared = VXKeyboardController()
    struct Request: Equatable { let id: Int; let prompt: String; let text: String; let maxChars: Int; let singleLine: Bool }
    @Published private(set) var request: Request?
    private var nextID = 1
    private var openAction: (() -> Void)?
    private var closeAction: (() -> Void)?

    /// Installs the bridge hook (call once, early). The callbacks arrive on the game's thread.
    nonisolated static func install() {
        vx_xrizer_guest_set_keyboard_hook({ prompt, existing, maxChars, singleLine, _ in
            let p = prompt.map { String(cString: $0) } ?? "", e = existing.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { VXKeyboardController.shared.present(prompt: p, text: e, maxChars: Int(maxChars), singleLine: singleLine != 0) }
        }, { _ in
            DispatchQueue.main.async { VXKeyboardController.shared.dismiss() }
        }, nil)
    }
    /// A view that can open and close the keyboard window registers here (the Environment's actions exist only in views).
    func attach(open: @escaping () -> Void, close: @escaping () -> Void) { openAction = open; closeAction = close }

    private func present(prompt: String, text: String, maxChars: Int, singleLine: Bool) {
        guard let open = openAction else {   // nothing can show a window: let the game carry on with the text it offered
            vxrt_jlog("keyboard", "\"event\":\"no_opener\"")
            vx_xrizer_guest_keyboard_complete(text, 0)
            return
        }
        VXLifecycle.keyboardOpen = true
        request = Request(id: nextID, prompt: prompt, text: text, maxChars: maxChars, singleLine: singleLine); nextID += 1
        vxrt_jlog("keyboard", "\"event\":\"open\",\"prompt\":\"\(prompt)\",\"max\":\(maxChars)")
        open()
    }
    /// The wearer finished. `text` nil = cancelled.
    func finish(_ id: Int, text: String?) {
        guard let r = request, r.id == id else { return }
        request = nil; VXLifecycle.keyboardOpen = false
        vxrt_jlog("keyboard", "\"event\":\"\(text == nil ? "cancel" : "done")\",\"chars\":\(text?.count ?? 0)")
        if let text { vx_xrizer_guest_keyboard_complete(text, 1) } else { vx_xrizer_guest_keyboard_complete(r.text, 0) }
        closeAction?()
    }
    /// The game hid the keyboard (HideKeyboard) before the wearer finished.
    private func dismiss() {
        guard request != nil else { return }
        request = nil; VXLifecycle.keyboardOpen = false
        vxrt_jlog("keyboard", "\"event\":\"hidden_by_game\"")
        closeAction?()
    }
}

struct VXKeyboardScene: Scene {
    var body: some Scene {
        WindowGroup(id: "keyboard") { VXKeyboardView() }
            .defaultSize(width: 560, height: 230)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
    }
}

struct VXKeyboardOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    func body(content: Content) -> some View {
        content.onAppear {
            VXKeyboardController.shared.attach(open: { openWindow(id: "keyboard") }, close: { dismissWindow(id: "keyboard") })
        }
    }
}
extension View { func vxKeyboardOpener() -> some View { modifier(VXKeyboardOpener()) } }

struct VXKeyboardView: View {
    @ObservedObject private var controller = VXKeyboardController.shared
    @State private var text = ""
    @State private var shownID = 0
    @FocusState private var focused: Bool
    var body: some View {
        let request = controller.request
        VStack(spacing: 16) {
            Text(request?.prompt.isEmpty == false ? request!.prompt : "Enter text").font(.headline)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .onSubmit { done() }
                .onChange(of: text) { _, new in
                    if let m = request?.maxChars, m > 0, new.count > m { text = String(new.prefix(m)) }
                }
            HStack(spacing: 20) {
                Button("Cancel", role: .cancel) { cancel() }
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .onAppear { load(request) }
        .onChange(of: request) { _, r in load(r) }
        .onDisappear { cancel() }   // the window was closed by the wearer
    }
    private func load(_ r: VXKeyboardController.Request?) {
        guard let r, r.id != shownID else { return }
        shownID = r.id; text = r.text
        DispatchQueue.main.async { focused = true }
    }
    private func done() { if let r = controller.request { controller.finish(r.id, text: text) } }
    private func cancel() { if let r = controller.request { controller.finish(r.id, text: nil) } }
}
