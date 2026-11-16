// The settings window: pages in a sidebar on the left, the page's controls in the middle, and on the right what the setting being
// looked at does, with a general picture of it. The first page is Presets (VXPresets.swift). The layout is the one AVP Play's other
// games got on 2026-11-16 (Klepton's KleptonSettingsWindow.swift, reimplemented here; Klepton is MIT), itself after LambdaVision's
// Half-Life settings, which the owner liked: "mit seinem zwei bzw drei geteilten Layout und den presets". Skyrim's own options (its
// ini values) get pages of their own by group, as there are many of them.
//
// The controls are the same stored settings as before (VXSettings), so nothing a player chose changes with the window. The pictures
// on the right come from the app's Help folder: one scene made for this, shown with and without a setting (no game's art).
import SwiftUI
import UIKit
import Darwin

enum VXDevice {
    /// Which Vision Pro this is; VXRT_DEVICE_KIND=m2|m5 overrides, to see the other's window.
    static let kind: VXDeviceKind = {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var raw = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &raw, &size, nil, 0)
        return VXDeviceKind.from(model: String(cString: raw), override: ProcessInfo.processInfo.environment["VXRT_DEVICE_KIND"])
    }()
}

// MARK: - The explanation column

final class VXSettingsFocus: ObservableObject { @Published var key: String? }

private struct VXHelpModifier: ViewModifier {
    @EnvironmentObject private var focus: VXSettingsFocus
    let key: String
    /// With the ⓘ button beside it (a row puts it beside its title instead).
    let info: Bool
    func body(content: Content) -> some View {
        Group {
            if info {
                HStack(alignment: .top, spacing: 8) { content.frame(maxWidth: .infinity, alignment: .leading); VXInfoButton(key: key) }
            } else {
                content
            }
        }
        .contentShape(Rectangle())
        .onHover { if $0 { focus.key = key } }
        .simultaneousGesture(TapGesture().onEnded { focus.key = key })
    }
}

/// The ⓘ beside a setting: shows its explanation on the right – a tap, so it works by touch as well (the owner's finding,
/// 2026-11-16: by touch the column did not always follow).
struct VXInfoButton: View {
    @EnvironmentObject private var focus: VXSettingsFocus
    let key: String
    var body: some View {
        Button { focus.key = key } label: {
            Image(systemName: focus.key == key ? "info.circle.fill" : "info.circle")
                .foregroundStyle(focus.key == key ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(vxT("What this does", "Was das bewirkt"))
    }
}

extension View {
    /// Shows `key`'s explanation on the right while this is looked at or touched, with an ⓘ button beside it.
    func vxHelp(_ key: String, info: Bool = true) -> some View { modifier(VXHelpModifier(key: key, info: info)) }
}

/// A switch with its name, the ⓘ beside the name and the switch on the right.
struct VXToggleRow: View {
    let title: String
    let help: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            VXInfoButton(key: help)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).labelsHidden()
        }
        .vxHelp(help, info: false)
    }
}

/// Watches the settings the pages show and, when one changes – by touch, by looking and pinching –, shows its explanation
/// on the right. Not on the presets page, where applying a preset changes many at once.
struct VXFollowChanges: View {
    let active: Bool
    @EnvironmentObject private var focus: VXSettingsFocus
    @ObservedObject private var settings = VXSettings.shared
    private func show(_ key: String) { if active { focus.key = key } }
    var body: some View {
        Color.clear
            .onChange(of: settings.baseResolution) { _, _ in show("baseResolution") }
            .onChange(of: settings.renderScale) { _, _ in show("resolution") }
            .onChange(of: settings.upscale) { _, _ in show("upscale") }
            .onChange(of: settings.foveatedRendering) { _, _ in show("foveation") }
            .onChange(of: settings.edgeMask) { _, _ in show("edgeMask") }
            .onChange(of: settings.displayQuality) { _, _ in show("displayQuality") }
            .onChange(of: settings.plainResample) { _, _ in show("filter") }
            .onChange(of: settings.maxRate) { _, _ in show("frameRate") }
            .onChange(of: settings.latency) { _, _ in show("latency") }
            .onChange(of: settings.showHands) { _, _ in show("hands") }
            .onChange(of: settings.statsPanel) { _, _ in show("panel") }
            .onChange(of: settings.startAutomatically) { _, _ in show("autoStart") }
            .onChange(of: settings.gameLanguage) { _, _ in show("language") }
            .onChange(of: settings.graphics) { _, _ in show("graphics") }
            .onChange(of: settings.turn) { _, _ in show("controls") }
            .onChange(of: settings.move) { _, _ in show("controls") }
            .onChange(of: settings.snapAngle) { _, _ in show("controls") }
            .onChange(of: settings.turnSpeed) { _, _ in show("controls") }
            .accessibilityHidden(true)
    }
}

struct VXHelpEntry {
    let title: String
    let text: String
    var pictures: [(label: String, file: String)] = []
    var note: String? = nil
}

enum VXHelp {
    static var nextStart: String { vxT("Applies the next time you start the game.", "Gilt ab dem nächsten Start des Spiels.") }
    static var atOnce: String { vxT("Applies at once.", "Gilt sofort.") }
    private static func pair(_ name: String, _ a: String, _ b: String) -> [(label: String, file: String)] {
        [(a, "KLHelp-\(name)-a"), (b, "KLHelp-\(name)-b")]
    }

    static func entry(_ key: String) -> VXHelpEntry? {
        let r = VXDevice.kind.rates
        switch key {
        case "presets", "preset.m5":
            return VXHelpEntry(title: "Vision Pro M5",
                               text: vxT("The picture settings the app starts with. Choosing it again puts every picture setting back.",
                                         "Die Bildeinstellungen, mit denen die App startet. Wer es wieder wählt, setzt alle Bildeinstellungen zurück."),
                               pictures: [("M5", "KLHelp-scene")],
                               note: vxT("A preset sets the picture only; frame rate, smoothness and the game's options stay. ", "Ein Preset setzt nur das Bild; Bildrate, Flüssigkeit und die Optionen des Spiels bleiben. ") + nextStart)
        case "preset.m5.performance":
            return VXHelpEntry(title: vxT("Performance", "Leistung"),
                               text: vxT("75 % with MetalFX upscaling. Where the app starts like that already, from one base resolution smaller – or, at the smallest base, with foveated rendering in the game's passes. Smoother and cooler, a little softer.",
                                         "75 % mit MetalFX-Hochskalieren. Wo die App schon so startet, von einer kleineren Basisauflösung aus – oder, bei der kleinsten Basis, mit Foveated Rendering im Spiel. Flüssiger und kühler, etwas weicher."),
                               pictures: pair("resolution", vxT("Smaller", "Kleiner"), vxT("Larger", "Größer")), note: nextStart)
        case "preset.m5.quality":
            return VXHelpEntry(title: vxT("Quality", "Qualität"),
                               text: vxT("The next larger base resolution, the whole picture drawn – no edge left out – and the highest display quality. Sharper, especially at the edges of view and in text; the frame rate may drop in busy places.",
                                         "Die nächstgrößere Basisauflösung, das ganze Bild gezeichnet – kein Rand ausgelassen – und die höchste Anzeigequalität. Schärfer, vor allem am Rand des Blickfelds und bei Schrift; an belebten Orten kann die Bildrate sinken."),
                               pictures: pair("view", vxT("Edge left out", "Rand ausgelassen"), vxT("Whole picture", "Ganzes Bild")), note: nextStart)
        case "preset.own":
            return VXHelpEntry(title: vxT("Your own presets", "Eigene Presets"),
                               text: vxT("Save the picture as it is set now under a name of your own. Share sends a preset as text – to a friend or to the AVP Play community on GitHub – and Paste reads one back in. Owners of a Vision Pro with the M2 are especially welcome to make and share presets for it: the ones that come with the app were tuned on an M5.",
                                         "Speichere das Bild, wie es gerade eingestellt ist, unter einem eigenen Namen. Teilen schickt ein Preset als Text – an Freunde oder an die AVP-Play-Community auf GitHub –, Einfügen liest eins wieder ein. Besitzer einer Vision Pro mit M2 sind ausdrücklich eingeladen, Presets dafür zu bauen und zu teilen: Die mitgelieferten sind auf einer M5 abgestimmt."))
        case "device":
            return VXHelpEntry(title: vxT("Your Vision Pro", "Deine Vision Pro"),
                               text: VXDevice.kind == .m2
                               ? vxT("A Vision Pro with the M2 chip. Its display runs at up to 100 Hz, so the frame rate choices are 90 and 100. The presets were tuned on an M5 – start from \"Performance\" and save what runs well.",
                                     "Eine Vision Pro mit M2-Chip. Ihr Display läuft mit bis zu 100 Hz, deshalb stehen bei der Bildrate 90 und 100 zur Wahl. Die Presets sind auf einer M5 abgestimmt – fang mit „Leistung“ an und speichere, was gut läuft.")
                               : vxT("A Vision Pro with the M5 chip, the one the presets were tuned on. Its display runs at up to 120 Hz.",
                                     "Eine Vision Pro mit M5-Chip, auf der die Presets abgestimmt wurden. Ihr Display läuft mit bis zu 120 Hz."))
        case "baseResolution":
            return VXHelpEntry(title: vxT("Base resolution per eye", "Basisauflösung je Auge"),
                               text: vxT("The width in pixels of the picture each eye is drawn for; Resolution is a share of it, and MetalFX enlarges to it. Higher is sharper and costs graphics time: the game draws about as many more pixels as the number grows, squared.",
                                         "Die Breite in Pixeln des Bildes, für das jedes Auge gezeichnet wird; die Auflösung ist ein Anteil davon, und MetalFX vergrößert darauf. Höher ist schärfer und kostet Grafikzeit: Das Spiel zeichnet etwa so viel mehr Pixel, wie die Zahl wächst, im Quadrat."),
                               pictures: pair("resolution", vxT("Smaller", "Kleiner"), vxT("Larger", "Größer")), note: nextStart)
        case "resolution":
            return VXHelpEntry(title: vxT("Resolution", "Auflösung"),
                               text: vxT("How finely the game is drawn, as a share of the base resolution. Lower it if the picture stutters when you look around. With MetalFX on, the size it enlarges. 75 % is the default.",
                                         "Wie fein das Spiel gezeichnet wird, als Anteil der Basisauflösung. Verringern, wenn das Bild beim Umsehen ruckelt. Mit MetalFX die Größe, die es vergrößert. Üblich sind 75 %."),
                               pictures: pair("resolution", vxT("Lower", "Niedriger"), vxT("Higher", "Höher")), note: nextStart)
        case "upscale":
            return VXHelpEntry(title: vxT("Upscaling", "Hochskalieren"),
                               text: vxT("Apple's MetalFX brings the game's picture up to the display's size: sharper than plain scaling, at a little graphics time. Plain simply stretches it: softer, with no extra work.",
                                         "Apples MetalFX bringt das Bild des Spiels auf die Größe der Anzeige: schärfer als einfaches Skalieren, für etwas Grafikzeit. Einfach streckt es nur: weicher, ohne zusätzliche Arbeit."),
                               pictures: pair("metalfx", vxT("Plain", "Einfach"), "MetalFX"), note: nextStart)
        case "displayQuality":
            return VXHelpEntry(title: vxT("Display quality", "Anzeigequalität"),
                               text: vxT("How finely the finished picture is drawn into the display. That happens on every display frame, up to 100 times a second whatever the game's own rate, and takes a large part of the graphics time. Lower leaves more for the game and is a little softer. Needs the high-resolution display (Advanced).",
                                         "Wie fein das fertige Bild in die Anzeige gezeichnet wird. Das passiert bei jedem Anzeigebild, bis zu 100-mal pro Sekunde, egal wie schnell das Spiel selbst ist, und kostet einen großen Teil der Grafikzeit. Niedriger lässt dem Spiel mehr übrig und ist etwas weicher. Braucht die hochauflösende Anzeige (Erweitert)."),
                               pictures: pair("output", vxT("Low", "Niedrig"), vxT("High", "Hoch")), note: nextStart)
        case "filter":
            return VXHelpEntry(title: vxT("Picture filter", "Bildfilter"),
                               text: vxT("\"Sharp\" keeps fine detail steady while you move your head; \"Plain\" takes a fifth of the samples and saves graphics time, at the price of a slight shimmer on fine detail.",
                                         "„Scharf“ hält feine Details ruhig, während du den Kopf bewegst; „Einfach“ braucht ein Fünftel der Abtastungen und spart Grafikzeit, um den Preis eines leichten Flimmerns an feinen Details."),
                               note: nextStart)
        case "foveation":
            return VXHelpEntry(title: "Foveated Rendering",
                               text: vxT("The game draws the middle of the picture at full sharpness and the edge with fewer pixels, which makes it run more smoothly. The stronger, the more you may notice a soft edge when you look sideways.",
                                         "Das Spiel zeichnet die Bildmitte in voller Schärfe und den Rand mit weniger Pixeln und läuft dadurch flüssiger. Je stärker, desto eher fällt ein weicher Rand auf, wenn du zur Seite schaust."),
                               pictures: pair("foveation", vxT("Off", "Aus"), vxT("On", "An")), note: nextStart)
        case "edgeMask":
            return VXHelpEntry(title: vxT("Unseen edge", "Unsichtbarer Rand"),
                               text: vxT("The game can leave out the edge of the picture that the lenses do not show, which makes it run more smoothly. If you see a black bar or black corners in the game, choose less; \"Draw everything\" never shows one.",
                                         "Das Spiel kann den Rand des Bildes auslassen, den die Linsen nicht zeigen, und läuft dann flüssiger. Siehst du im Spiel einen schwarzen Balken oder schwarze Ecken, wähle weniger; „Alles zeichnen“ zeigt nie einen."),
                               pictures: pair("view", vxT("Left out", "Ausgelassen"), vxT("Everything", "Alles")), note: nextStart)
        case "frameRate":
            return VXHelpEntry(title: vxT("Frame rate", "Bildrate"),
                               text: vxT("How often the display shows a picture; the game's own pictures come more slowly and are fitted to your head in between. Up to \(r.mixed) is the default. Up to \(r.full) is smoother where the display can do it. When the app cannot keep up, the Vision Pro halves the rate for a while: to \(r.mixed / 2) or \(r.full / 2).",
                                         "Wie oft die Anzeige ein Bild zeigt; die Bilder des Spiels kommen langsamer und werden dazwischen an deinen Kopf angepasst. Bis \(r.mixed) ist der Standard. Bis \(r.full) ist flüssiger, wo das Display es kann. Kommt die App nicht mit, halbiert die Vision Pro die Rate eine Weile: auf \(r.mixed / 2) oder \(r.full / 2).")
                               + (VXDevice.kind == .m2 ? vxT(" This Vision Pro has the M2: its display has no 120 Hz.", " Diese Vision Pro hat den M2: Ihr Display kann keine 120 Hz.") : ""),
                               pictures: [(vxT("Frame rate", "Bildrate"), "KLHelp-framerate")], note: nextStart)
        case "latency":
            return VXHelpEntry(title: vxT("Smoothness", "Flüssigkeit"),
                               text: vxT("Balanced: the game starts each frame as the display frees up – the most frames a second without older head positions. Fresher picture: a frame starts only once the previous one is on its way, built from a fresher head position, at fewer frames a second. Most frames: the game runs ahead freely, each frame from an older head position.",
                                         "Ausgewogen: Das Spiel beginnt jedes Bild, sobald die Anzeige frei wird – die meisten Bilder pro Sekunde ohne ältere Kopfpositionen. Frischeres Bild: Ein Bild beginnt erst, wenn das vorige unterwegs ist, aus einer frischeren Kopfposition, mit weniger Bildern pro Sekunde. Meiste Bilder: Das Spiel läuft frei voraus, jedes Bild aus einer älteren Kopfposition."),
                               note: atOnce)
        case "hands":
            return VXHelpEntry(title: vxT("Your hands", "Deine Hände"),
                               text: vxT("The game draws its own hands and controllers, so your real ones would be a second pair in the same place.",
                                         "Das Spiel zeichnet eigene Hände und Controller; deine echten wären ein zweites Paar an derselben Stelle."), note: atOnce)
        case "panel":
            return VXHelpEntry(title: vxT("Performance panel", "Leistungsanzeige"),
                               text: vxT("Frame rate, graphics and processor time, memory and heat, above the middle of the view. In the game, hold Create and Options together for a second to show or hide it.",
                                         "Bildrate, Grafik- und Prozessorzeit, Speicher und Wärme, über der Mitte des Blickfelds. Im Spiel Create und Options eine Sekunde zusammen halten, um sie zu zeigen oder auszublenden."))
        case "autoStart":
            return VXHelpEntry(title: vxT("Start automatically", "Automatisch starten"),
                               text: vxT("Off: the start window waits for Start. On: the game starts \(VXSettings.autoStartDelay) seconds after the app opens; until then you can cancel or change settings.",
                                         "Aus: Das Startfenster wartet auf Start. An: Das Spiel startet \(VXSettings.autoStartDelay) Sekunden nach dem Öffnen der App; bis dahin kannst du abbrechen oder Einstellungen ändern."))
        case "game":
            return VXHelpEntry(title: vxT("The game's own options", "Die Optionen des Spiels"),
                               text: vxT("Skyrim VR's own settings, written over its SkyrimPrefs.ini at the start. \"Game default\" changes nothing: the game keeps its own value.",
                                         "Die eigenen Einstellungen von Skyrim VR, beim Start über seine SkyrimPrefs.ini geschrieben. „Wie im Spiel“ ändert nichts: Das Spiel behält seinen eigenen Wert."),
                               note: nextStart)
        case "language":
            return VXHelpEntry(title: vxT("Game language", "Sprache des Spiels"),
                               text: vxT("The language of the game's texts and, where its voice pack is installed, its voices. A language pack is chosen on the game's page in AVP Play.",
                                         "Die Sprache der Texte des Spiels und, wo ihr Sprachpaket installiert ist, seiner Stimmen. Ein Sprachpaket wählst du auf der Seite des Spiels in AVP Play."),
                               note: nextStart)
        case "graphics":
            return VXHelpEntry(title: vxT("Graphics quality", "Grafikqualität"),
                               text: vxT("The game's own scene detail: shadows, distant objects, trees and grass. Low also takes work off the processor – the one to try when the game stutters. Standard is the balanced values this app starts with.",
                                         "Die Szenendetails des Spiels selbst: Schatten, ferne Objekte, Bäume und Gras. Niedrig entlastet auch den Prozessor – die Stufe zum Ausprobieren, wenn das Spiel ruckelt. Standard sind die ausgewogenen Werte, mit denen diese App startet."),
                               note: nextStart)
        case "controls":
            return VXHelpEntry(title: vxT("Turning and movement", "Drehen und Bewegung"),
                               text: vxT("Snap turning turns you in steps with a flick of the right stick, smooth turning while you hold it. Teleport: push the left stick forward to aim, release to jump; Walk moves you directly.",
                                         "Drehen in Schritten dreht dich mit einem Tipp am rechten Stick, fließend, solange du ihn hältst. Teleport: Linken Stick nach vorn drücken zum Zielen, loslassen zum Springen; Gehen bewegt dich direkt."),
                               note: nextStart)
        case "mods":
            return VXHelpEntry(title: "Mods", text: vxT("The mods the Mac prepared for this installation. They are chosen in AVP Play before installing.",
                                                        "Die Mods, die der Mac für diese Installation vorbereitet hat. Gewählt werden sie in AVP Play vor der Installation."))
        case "advanced":
            return VXHelpEntry(title: vxT("Advanced", "Erweitert"),
                               text: vxT("Dials of the port itself: sharpening, how the picture reaches the headset, controller alignment, head prediction and eye height. Nothing here is needed to play.",
                                         "Regler der Portierung selbst: Nachschärfen, wie das Bild ans Headset geht, Controller-Ausrichtung, Kopf-Vorhersage und Augenhöhe. Nichts davon braucht man zum Spielen."))
        case "diagnostics":
            return VXHelpEntry(title: vxT("Diagnostics", "Diagnose"),
                               text: vxT("The logs of the last run, to pass on when something goes wrong.", "Die Protokolle des letzten Laufs, zum Weitergeben, wenn etwas nicht stimmt."))
        default:
            return nil
        }
    }
}

struct VXHelpPane: View {
    @EnvironmentObject private var focus: VXSettingsFocus
    let pageKey: String
    /// The explanation shown large (the owner's wish, 2026-11-16: "Wenn man drauf klickt kommt ein größeres Bild ebenfalls mit
    /// der Beschreibung, wo man dann gern wechseln kann zwischen beiden Varianten"). VXRT_SETTINGS_ZOOM=1 opens it from the start.
    @State private var enlarged: String? = ProcessInfo.processInfo.environment["VXRT_SETTINGS_ZOOM"] == "1"
        ? ProcessInfo.processInfo.environment["VXRT_SETTINGS_HELP"] : nil

    var body: some View {
        let key = focus.key ?? pageKey
        let shownKey = VXHelp.entry(key) != nil ? key : pageKey
        if let e = VXHelp.entry(shownKey) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // A picture only where there is something to compare (the owner's word).
                    if e.pictures.count >= 2 {
                        Button { enlarged = shownKey } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                VXHelpPictures(pictures: e.pictures)
                                Label(vxT("Tap to enlarge", "Zum Vergrößern antippen"), systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .hoverEffect()
                    }
                    VXHelpText(entry: e)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(isPresented: Binding(get: { enlarged != nil }, set: { if !$0 { enlarged = nil } })) {
                if let k = enlarged, let big = VXHelp.entry(k) { VXHelpLarge(entry: big) { enlarged = nil } }
            }
        } else {
            ContentUnavailableView(vxT("Look at a setting", "Schau auf eine Einstellung"), systemImage: "eye",
                                   description: Text(vxT("What it does appears here.", "Hier steht, was sie bewirkt.")))
        }
    }
}

struct VXHelpText: View {
    let entry: VXHelpEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.title).font(.title3.weight(.semibold))
            Text(entry.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = entry.note { Label(note, systemImage: "arrow.clockwise").font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

/// A picture from the app's Help folder, or a quiet placeholder.
struct VXHelpImage: View {
    let file: String
    private static func image(_ name: String) -> UIImage? {
        Bundle.main.path(forResource: name, ofType: "jpg", inDirectory: "Help").flatMap(UIImage.init(contentsOfFile:))
    }
    var body: some View {
        Group {
            if let img = Self.image(file) { Image(uiImage: img).resizable().scaledToFill() }
            else { Rectangle().fill(.gray.opacity(0.25)) }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// One picture, or two as a split picture: the first variant on the left half, the second on the right, named in the corners.
struct VXHelpPictures: View {
    let pictures: [(label: String, file: String)]
    var body: some View {
        if pictures.count >= 2 {
            VXHelpImage(file: pictures[1].file)
                .overlay {
                    VXHelpImage(file: pictures[0].file)
                        .mask { GeometryReader { g in Rectangle().frame(width: g.size.width / 2).frame(maxWidth: .infinity, alignment: .leading) } }
                }
                .overlay { Rectangle().fill(.white.opacity(0.9)).frame(width: 2) }
                .overlay(alignment: .bottomLeading) { VXHelpTag(text: pictures[0].label) }
                .overlay(alignment: .bottomTrailing) { VXHelpTag(text: pictures[1].label) }
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else if let p = pictures.first {
            VXHelpImage(file: p.file)
        }
    }
}

struct VXHelpTag: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .padding(10)
    }
}

/// The large view: the picture big, a switch between its variants, the same words.
struct VXHelpLarge: View {
    let entry: VXHelpEntry
    let close: () -> Void
    @State private var shown = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if entry.pictures.count >= 2 {
                let i = min(shown, entry.pictures.count - 1)
                VXHelpImage(file: entry.pictures[i].file)
                    .id(entry.pictures[i].file)
                    .transition(.opacity)
                    .overlay(alignment: .bottomLeading) { VXHelpTag(text: entry.pictures[i].label) }
                    .frame(maxWidth: 880)
                if entry.pictures.count > 1 {
                    Picker(vxT("Variant", "Variante"), selection: $shown) {
                        ForEach(entry.pictures.indices, id: \.self) { Text(entry.pictures[$0].label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520).frame(maxWidth: .infinity)
                }
            }
            VXHelpText(entry: entry).frame(maxWidth: 880, alignment: .leading)
            HStack { Spacer(); Button(vxT("Close", "Schließen"), action: close) }
        }
        .padding(28).frame(width: 940)
        .animation(.easeInOut(duration: 0.2), value: shown)
    }
}

struct VXPage<Content: View>: View {
    let title: String
    let help: String
    /// Above the explanation in the right column (the presets page: what has changed since the preset).
    var side: AnyView? = nil
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(spacing: 0) {
                if let side { side.padding(.horizontal, 20).padding(.top, 20) }
                VXHelpPane(pageKey: help)
            }
            .frame(width: 380)
        }
        .navigationTitle(title)
    }
}

struct VXBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        GroupBox(title) { VStack(alignment: .leading, spacing: 12) { content }.frame(maxWidth: .infinity, alignment: .leading) }
    }
}

struct VXRow<Control: View>: View {
    let title: String
    let help: String
    /// The control under the title, the page's whole width (a long row of choices).
    var stacked = false
    @ViewBuilder let control: Control
    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { Text(title); VXInfoButton(key: help) }; control }
            } else {
                HStack(spacing: 8) { Text(title); VXInfoButton(key: help); Spacer(minLength: 12); control }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vxHelp(help, info: false)
    }
}

// MARK: - The window

enum VXSettingsPageID: Hashable {
    case presets, picture, motion, hands, game, controls, ini(VXIniSetting.Group), mods, start, advanced, diagnostics
}

struct VXSettingsWindow: View {
    let done: () -> Void
    @ObservedObject private var settings = VXSettings.shared
    @ObservedObject private var launcher = VXLauncher.shared
    @StateObject private var focus = VXSettingsFocus()
    @State private var selection: VXSettingsPageID? = Self.startPage
    /// A scripted launch can open a page and an explanation (VXRT_SETTINGS_PAGE=picture|motion|hands|game|controls|mods|start|advanced|
    /// diagnostics, VXRT_SETTINGS_HELP=<key>), to photograph them without a hand to tap; VXRT_START_GAME_SETTINGS=1 is the game page.
    private static var startPage: VXSettingsPageID {
        let env = ProcessInfo.processInfo.environment
        if env["VXRT_START_GAME_SETTINGS"] == "1" { return .game }
        switch env["VXRT_SETTINGS_PAGE"] {
        case "picture": return .picture
        case "motion": return .motion
        case "hands": return .hands
        case "game": return .game
        case "controls": return .controls
        case "mods": return .mods
        case "start": return .start
        case "advanced": return .advanced
        case "diagnostics": return .diagnostics
        default: return .presets
        }
    }
    @State private var generation = 0

    private var activeName: String {
        let store = VXPresetStore()
        switch VXPresetRules.matching(settings.picture, standard: VXSettings.standardPicture(info: Bundle.main.infoDictionary ?? [:]), custom: store.presets) {
        case .builtIn(let k)?: return k.name
        case .custom(let id)?: return store.presets.first { $0.id == id }?.name ?? ""
        case nil: return vxT("Custom", "Eigene")
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section { row(.presets, vxT("Presets", "Presets"), "slider.horizontal.3", activeName) }
                Section(vxT("Look", "Bild")) {
                    row(.picture, vxT("Picture", "Bild"), "sparkles.tv",
                        "\(settings.baseResolution > 0 ? settings.baseResolution : VXSettings.baseResolutionStandard) · " + String(format: "%.0f %%", settings.renderScale * 100))
                    row(.motion, vxT("Frame rate", "Bildrate"), "speedometer",
                        vxT("Up to ", "Bis ") + "\(settings.maxRate == 120 ? VXDevice.kind.rates.full : VXDevice.kind.rates.mixed)")
                    row(.hands, vxT("Hands & panel", "Hände & Anzeige"), "hand.raised")
                }
                Section(vxT("Game", "Spiel")) {
                    row(.game, vxT("Language & graphics", "Sprache & Grafik"), "character.bubble")
                    row(.controls, vxT("Turning & movement", "Drehen & Bewegung"), "figure.walk")
                    ForEach(VXIniSetting.Group.allCases, id: \.self) { g in
                        row(.ini(g), g.title, Self.symbol(g))
                    }
                    row(.mods, "Mods", "puzzlepiece.extension")
                }
                Section {
                    row(.start, vxT("Start", "Start"), "play.circle")
                    row(.advanced, vxT("Advanced", "Erweitert"), "wrench.and.screwdriver")
                    row(.diagnostics, vxT("Diagnostics", "Diagnose"), "doc.text.magnifyingglass")
                }
            }
            .navigationTitle(vxT("Settings", "Einstellungen"))
            .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 340)
        } detail: {
            page(selection ?? .presets).id(selection).onAppear { focus.key = ProcessInfo.processInfo.environment["VXRT_SETTINGS_HELP"] }
                .background { VXFollowChanges(active: selection != .presets) }
        }
        .environmentObject(focus)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(vxT("Done", "Fertig"), action: done) } }
    }

    private static func symbol(_ g: VXIniSetting.Group) -> String {
        switch g {
        case .controls: return "gamecontroller"
        case .comfort: return "eye"
        case .body: return "figure.stand"
        case .interface: return "text.bubble"
        case .teleport: return "arrow.up.forward.circle"
        }
    }

    private func row(_ id: VXSettingsPageID, _ title: String, _ symbol: String, _ value: String = "") -> some View {
        NavigationLink(value: id) {
            LabeledContent { Text(value).lineLimit(1) } label: { Label(title, systemImage: symbol) }
        }
    }

    @ViewBuilder private var startedNote: some View {
        Label(launcher.started ? vxT("The game is running: changes to the picture apply the next time you open the app.",
                                     "Das Spiel läuft: Änderungen am Bild gelten beim nächsten Öffnen der App.")
                               : vxT("Changes to the picture apply the next time you start the game.",
                                     "Änderungen am Bild gelten beim nächsten Start des Spiels."),
              systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private func page(_ id: VXSettingsPageID) -> some View {
        switch id {
        case .presets: VXPage(title: vxT("Presets", "Presets"), help: "presets", side: AnyView(VXPresetChanges())) { VXPresetsPage() }
        case .picture: VXPage(title: vxT("Picture", "Bild"), help: "baseResolution") { VXPicturePage(); startedNote }
        case .motion: VXPage(title: vxT("Frame rate", "Bildrate"), help: "frameRate") { VXMotionPage(); startedNote }
        case .hands: VXPage(title: vxT("Hands & panel", "Hände & Anzeige"), help: "hands") { VXHandsPage() }
        case .game: VXPage(title: vxT("Language & graphics", "Sprache & Grafik"), help: "game") { VXGameLanguagePage() }
        case .controls: VXPage(title: vxT("Turning & movement", "Drehen & Bewegung"), help: "controls") { VXTurnMovePage() }
        case .ini(let g): VXPage(title: g.title, help: "game") { VXIniPage(group: g) }
        case .mods: VXPage(title: "Mods", help: "mods") { VXModsList() }
        case .start: VXPage(title: vxT("Start", "Start"), help: "autoStart") {
            VXBox(title: vxT("Start", "Start")) {
                VXToggleRow(title: vxT("Start automatically", "Automatisch starten"), help: "autoStart", isOn: $settings.startAutomatically)
            }
        }
        case .advanced: VXPage(title: vxT("Advanced", "Erweitert"), help: "advanced") { VXAdvancedPage() }
        case .diagnostics: VXPage(title: vxT("Diagnostics", "Diagnose"), help: "diagnostics") { VXDiagnosticsPage() }
        }
    }
}

// MARK: - Presets

/// The presets page's right column, on top: which preset the picture comes from and what has changed since, dial by dial –
/// as LambdaVision's Half-Life shows it. Only the picture: the frame rate, smoothness, the game's options and the play area are
/// never part of a preset and so never shown here as a change.
struct VXPresetChanges: View {
    @ObservedObject private var settings = VXSettings.shared

    private func title(_ f: VXPictureField) -> String {
        switch f {
        case .baseResolution: return vxT("Base resolution per eye", "Basisauflösung je Auge")
        case .renderScale: return vxT("Resolution", "Auflösung")
        case .upscale: return vxT("Upscaling", "Hochskalieren")
        case .foveatedRendering: return "Foveated Rendering"
        case .edgeMask: return vxT("Unseen edge", "Unsichtbarer Rand")
        case .displayQuality: return vxT("Display quality", "Anzeigequalität")
        case .plainResample: return vxT("Picture filter", "Bildfilter")
        }
    }
    private func value(_ f: VXPictureField, _ p: VXPicture) -> String {
        switch f {
        case .baseResolution: return p.baseResolution == 0 ? "Standard (\(VXSettings.baseResolutionStandard))" : String(p.baseResolution)
        case .renderScale: return String(format: "%.0f %%", p.renderScale * 100)
        case .upscale: return p.upscale == VXUpscale.metalfx.rawValue ? "MetalFX" : vxT("Plain", "Einfach")
        case .foveatedRendering:
            return ["off": vxT("Off", "Aus"), "low": vxT("Low", "Leicht"), "medium": vxT("Medium", "Mittel"), "high": vxT("High", "Stark")][p.foveatedRendering] ?? p.foveatedRendering
        case .edgeMask:
            return ["off": vxT("Draw everything", "Alles zeichnen"), "slight": vxT("Skip a little", "Wenig auslassen"),
                    "standard": vxT("Skip more", "Mehr auslassen")][p.edgeMask] ?? p.edgeMask
        case .displayQuality: return p.displayQuality >= 0.99 ? vxT("High", "Hoch") : p.displayQuality >= 0.75 ? vxT("Medium", "Mittel") : vxT("Low", "Niedrig")
        case .plainResample: return p.plainResample ? vxT("Plain", "Einfach") : vxT("Sharp", "Scharf")
        }
    }

    var body: some View {
        let now = settings.picture
        let store = VXPresetStore()
        let standard = VXSettings.standardPicture(info: Bundle.main.infoDictionary ?? [:])
        let active = VXPresetRules.matching(now, standard: standard, custom: store.presets)
        var refName = VXBuiltInPreset.standard.name
        var refPicture = standard
        switch VXLastPreset().id {
        case .builtIn(let k)?: refName = k.name; refPicture = VXPresetRules.picture(k, standard: standard)
        case .custom(let u)?: if let p = store.presets.first(where: { $0.id == u }) { refName = p.name; refPicture = p.picture }
        case nil: break
        }
        let changes = VXPictureDiff.changes(from: refPicture, to: now)
        return VStack(alignment: .leading, spacing: 10) {
            if let active {
                let name: String = { switch active { case .builtIn(let k): return k.name; case .custom(let u): return store.presets.first { $0.id == u }?.name ?? "" } }()
                Label(vxT("Set: \(name)", "Eingestellt: \(name)"), systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                Text(vxT("Nothing changed since the preset.", "Seit dem Preset nichts geändert.")).font(.callout).foregroundStyle(.secondary)
            } else {
                Label(vxT("Changed since \"\(refName)\"", "Geändert seit „\(refName)“"), systemImage: "slider.horizontal.below.square.filled.and.square")
                    .font(.headline)
                ForEach(changes, id: \.self) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(f)).font(.callout.weight(.semibold))
                        Text("\(value(f, refPicture))  →  \(value(f, now))").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text(vxT("Save it as a preset of your own on the left, or choose a preset to go back.",
                         "Links als eigenes Preset speichern oder ein Preset wählen, um zurückzukehren."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Divider().padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VXPresetsPage: View {
    @ObservedObject private var settings = VXSettings.shared
    @State private var newName = ""
    @State private var renaming: VXCustomPreset?
    @State private var renameText = ""
    @State private var pasteResult = ""
    @State private var generation = 0
    private var store: VXPresetStore { VXPresetStore() }

    var body: some View {
        _ = generation
        let standard = VXSettings.standardPicture(info: Bundle.main.infoDictionary ?? [:])
        let now = settings.picture
        let custom = store.presets
        let active = VXPresetRules.matching(now, standard: standard, custom: custom)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "visionpro").font(.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text(vxT("This Vision Pro: ", "Diese Vision Pro: ") + VXDevice.kind.rawValue).font(.headline)
                    Text(VXDevice.kind == .m2
                         ? vxT("The presets that come with the app were tuned on an M5. Start from \"Performance\", save what runs well as a preset of your own and share it – M2 presets are very welcome.",
                               "Die mitgelieferten Presets sind auf einer M5 abgestimmt. Fang mit „Leistung“ an, speichere, was gut läuft, als eigenes Preset und teile es – M2-Presets sind ausdrücklich erwünscht.")
                         : vxT("The presets that come with the app were tuned on this kind of Vision Pro.",
                               "Die mitgelieferten Presets wurden auf dieser Art Vision Pro abgestimmt."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .vxHelp("device")
            VXBox(title: vxT("Come with the app", "Mitgeliefert")) {
                ForEach(VXBuiltInPreset.allCases) { k in
                    presetRow(k.name, detail(k), active == .builtIn(k), "preset.\(k.rawValue)") {
                        settings.apply(VXPresetRules.picture(k, standard: standard)); VXLastPreset().id = .builtIn(k); generation += 1
                    }
                    if k != VXBuiltInPreset.allCases.last { Divider() }
                }
            }
            VXBox(title: vxT("Your own", "Eigene")) {
                if custom.isEmpty {
                    Text(vxT("None yet. Set the picture the way you like it, then save it here.",
                             "Noch keine. Stell das Bild so ein, wie es dir gefällt, und speichere es hier."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(custom) { p in
                    HStack {
                        presetRow(p.name, p.device.isEmpty ? "" : "Vision Pro \(p.device)", active == .custom(p.id), "preset.own") {
                            settings.apply(p.picture); VXLastPreset().id = .custom(p.id); generation += 1
                        }
                        ShareLink(item: VXPresetStore.shareText(p)) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
                        Menu {
                            Button(vxT("Rename", "Umbenennen")) { renameText = p.name; renaming = p }
                            Button(vxT("Save the current picture into it", "Aktuelles Bild hineinspeichern")) {
                                store.save(name: p.name, picture: now, device: VXDevice.kind.rawValue); generation += 1
                            }
                            Button(vxT("Delete", "Löschen"), role: .destructive) { store.delete(p.id); generation += 1 }
                        } label: { Image(systemName: "ellipsis.circle") }.buttonStyle(.borderless)
                    }
                    Divider()
                }
                HStack {
                    TextField(vxT("Name for the current picture", "Name für das aktuelle Bild"), text: $newName).textFieldStyle(.roundedBorder)
                    Button(vxT("Save", "Speichern")) {
                        let saved = store.save(name: newName, picture: now, device: VXDevice.kind.rawValue)
                        VXLastPreset().id = .custom(saved.id); newName = ""; generation += 1
                    }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }.vxHelp("preset.own")
                HStack {
                    PasteButton(payloadType: String.self) { texts in
                        guard let t = texts.first, let p = VXPresetStore.parse(t) else {
                            pasteResult = vxT("That is not a shared preset.", "Das ist kein geteiltes Preset."); return
                        }
                        let s = store.save(name: p.name, picture: p.picture, device: p.device)
                        pasteResult = vxT("Added \"\(s.name)\".", "„\(s.name)“ hinzugefügt.")
                        generation += 1
                    }
                    if !pasteResult.isEmpty { Text(pasteResult).font(.callout).foregroundStyle(.secondary) }
                }.vxHelp("preset.own")
            }
            Label(vxT("A preset sets the picture; frame rate, smoothness and the game's options stay as you chose them. Changes apply the next time you start the game.",
                      "Ein Preset setzt das Bild; Bildrate, Flüssigkeit und die Optionen des Spiels bleiben, wie du sie gewählt hast. Änderungen gelten ab dem nächsten Start des Spiels."),
                  systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
        }
        .alert(vxT("Rename preset", "Preset umbenennen"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(vxT("Name", "Name"), text: $renameText)
            Button(vxT("Rename", "Umbenennen")) { if let p = renaming { store.rename(p.id, to: renameText); generation += 1 }; renaming = nil }
            Button(vxT("Cancel", "Abbrechen"), role: .cancel) { renaming = nil }
        }
    }

    /// What a built-in preset sets, from its own values: base, resolution, upscaling, and what differs from the standard.
    private func detail(_ k: VXBuiltInPreset) -> String {
        let standard = VXSettings.standardPicture(info: Bundle.main.infoDictionary ?? [:])
        let p = VXPresetRules.picture(k, standard: standard)
        let base = p.baseResolution > 0 ? "\(p.baseResolution)" : "\(VXSettings.baseResolutionStandard)"
        var parts = [base + String(format: vxT(" at %.0f %%", " mit %.0f %%"), p.renderScale * 100)
                     + (p.upscale == VXUpscale.metalfx.rawValue ? vxT(" with MetalFX", " und MetalFX") : "")]
        if p.edgeMask == VXEdgeMask.off.rawValue, standard.edgeMask != p.edgeMask { parts.append(vxT("whole picture", "ganzes Bild")) }
        if p.displayQuality > standard.displayQuality { parts.append(vxT("highest display quality", "höchste Anzeigequalität")) }
        if p.foveatedRendering != standard.foveatedRendering { parts.append(vxT("foveated rendering", "Foveated Rendering")) }
        if k == .standard { parts.append(vxT("the start settings", "die Starteinstellungen")) }
        return parts.joined(separator: k == .standard ? " – " : ", ")
    }

    private func presetRow(_ name: String, _ detail: String, _ active: Bool, _ help: String, apply: @escaping () -> Void) -> some View {
        Button(action: apply) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(.semibold))
                    if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).vxHelp(help)
    }
}

// MARK: - Picture, frame rate, hands

struct VXPicturePage: View {
    @ObservedObject private var settings = VXSettings.shared
    var body: some View {
        VXBox(title: vxT("Size", "Größe")) {
            VXRow(title: vxT("Base resolution per eye", "Basisauflösung je Auge"), help: "baseResolution") {
                Picker(vxT("Base resolution per eye", "Basisauflösung je Auge"), selection: $settings.baseResolution) {
                    ForEach(VXSettings.baseResolutions, id: \.self) { v in Text(verbatim: v == 0 ? "Standard (\(VXSettings.baseResolutionStandard))" : String(v)).tag(v) }
                }.labelsHidden()
            }
            HStack {
                Text(vxT("Resolution", "Auflösung"))
                Slider(value: Binding(get: { settings.renderScale }, set: { settings.renderScale = VXSettings.clampScale($0) }),
                       in: VXSettings.renderScaleRange, step: 0.05)
                Text(String(format: "%.0f %%", settings.renderScale * 100)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }.vxHelp("resolution")
            VXRow(title: vxT("Upscaling", "Hochskalieren"), help: "upscale") {
                Picker(vxT("Upscaling", "Hochskalieren"), selection: $settings.upscale) {
                    Text("MetalFX").tag(VXUpscale.metalfx)
                    Text(vxT("Plain", "Einfach")).tag(VXUpscale.bilinear)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
            }
        }
        VXBox(title: vxT("Detail", "Details")) {
            VXRow(title: "Foveated Rendering", help: "foveation", stacked: true) {
                Picker("Foveated Rendering", selection: $settings.foveatedRendering) {
                    Text(vxT("Off", "Aus")).tag(VXFoveatedRendering.off)
                    Text(vxT("Low", "Leicht")).tag(VXFoveatedRendering.low)
                    Text(vxT("Medium", "Mittel")).tag(VXFoveatedRendering.medium)
                    Text(vxT("High", "Stark")).tag(VXFoveatedRendering.high)
                }.pickerStyle(.segmented).labelsHidden()
            }
            // Three long choices: the title above them, not beside.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { Text(vxT("Unseen edge", "Unsichtbarer Rand")); VXInfoButton(key: "edgeMask") }
                Picker(vxT("Unseen edge", "Unsichtbarer Rand"), selection: $settings.edgeMask) {
                    Text(vxT("Draw everything", "Alles zeichnen")).tag(VXEdgeMask.off)
                    Text(vxT("Skip a little", "Wenig auslassen")).tag(VXEdgeMask.slight)
                    Text(vxT("Skip more", "Mehr auslassen")).tag(VXEdgeMask.standard)
                }.pickerStyle(.segmented).labelsHidden()
            }.vxHelp("edgeMask", info: false)
            VXRow(title: vxT("Display quality", "Anzeigequalität"), help: "displayQuality") {
                Picker(vxT("Display quality", "Anzeigequalität"), selection: Binding(get: { settings.displayQuality }, set: { settings.displayQuality = $0 })) {
                    Text(vxT("High", "Hoch")).tag(1.0)
                    Text(vxT("Medium", "Mittel")).tag(0.8)
                    Text(vxT("Low", "Niedrig")).tag(0.65)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340).disabled(!settings.foveation)
            }
            VXRow(title: vxT("Picture filter", "Bildfilter"), help: "filter") {
                Picker(vxT("Picture filter", "Bildfilter"), selection: $settings.plainResample) {
                    Text(vxT("Sharp", "Scharf")).tag(false)
                    Text(vxT("Plain", "Einfach")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
            }
        }
    }
}

struct VXMotionPage: View {
    @ObservedObject private var settings = VXSettings.shared
    var body: some View {
        let r = VXDevice.kind.rates
        VXBox(title: vxT("Frame rate", "Bildrate")) {
            VXRow(title: vxT("Frame rate", "Bildrate"), help: "frameRate") {
                Picker(vxT("Frame rate", "Bildrate"), selection: $settings.maxRate) {
                    Text(vxT("Up to \(r.mixed)", "Bis \(r.mixed)")).tag(100)
                    Text(vxT("Up to \(r.full)", "Bis \(r.full)")).tag(120)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
            }
            VXRow(title: vxT("Smoothness", "Flüssigkeit"), help: "latency", stacked: true) {
                Picker(vxT("Smoothness", "Flüssigkeit"), selection: $settings.latency) {
                    Text(vxT("Balanced", "Ausgewogen")).tag(VXLatency.smart)
                    Text(vxT("Fresher picture", "Frischeres Bild")).tag(VXLatency.lower)
                    Text(vxT("Most frames", "Meiste Bilder")).tag(VXLatency.throughput)
                }.pickerStyle(.segmented).labelsHidden()
            }
        }
        if VXDevice.kind == .m2 {
            Label(vxT("This Vision Pro has the M2: its display runs at up to 100 Hz, so the choices are 90 and 100.",
                      "Diese Vision Pro hat den M2: Ihr Display läuft mit bis zu 100 Hz, deshalb 90 und 100."), systemImage: "visionpro")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct VXHandsPage: View {
    @ObservedObject private var settings = VXSettings.shared
    var body: some View {
        VXBox(title: vxT("Your hands", "Deine Hände")) {
            VXToggleRow(title: vxT("Show my real hands over the game", "Meine echten Hände über dem Spiel zeigen"), help: "hands", isOn: $settings.showHands)
        }
        VXBox(title: vxT("Performance panel", "Leistungsanzeige")) {
            VXToggleRow(title: vxT("Show from the start", "Von Anfang an zeigen"), help: "panel", isOn: $settings.statsPanel)
        }
    }
}

// MARK: - The game's own options

struct VXGameLanguagePage: View {
    @ObservedObject private var settings = VXSettings.shared
    private var languageNote: String {
        let pack = vxT(" In AVP Play, pick the language on the game's page and install again.",
                       " In AVP Play auf der Seite des Spiels die Sprache wählen und erneut installieren.")
        let picked = settings.gameLanguage
        if picked != .auto, !settings.canUse(picked) {
            return vxT("\(picked.ownName) exists only with its language pack, which is not installed: the game starts in English.",
                       "\(picked.ownName) gibt es nur mit seinem Sprachpaket, und das ist nicht installiert: Das Spiel startet auf Englisch.") + pack
        }
        guard let language = settings.effectiveGameLanguage else {
            return vxT("Nothing is chosen: the game starts in English. The voices of another language are a download of their own.",
                       "Nichts gewählt: Das Spiel startet auf Englisch. Die Sprachausgabe einer anderen Sprache ist ein eigener Download.") + pack
        }
        let chosen = picked == .auto ? vxT("Automatic: ", "Automatisch: ") : ""
        if language == .zh {
            return chosen + vxT("\(language.ownName) texts with the English voices (the game has no Chinese voices).",
                                "Texte auf \(language.ownName), Stimmen auf Englisch (das Spiel hat keine chinesische Sprachausgabe).")
        }
        if language == .en || settings.hasVoices(language) {
            return chosen + vxT("\(language.ownName), texts and voices.", "\(language.ownName), Texte und Sprachausgabe.")
        }
        return chosen + vxT("\(language.ownName) texts with the English voices: this language's voices are not installed (about 2 GB).",
                            "Texte auf \(language.ownName), Stimmen auf Englisch: Die Sprachausgabe dieser Sprache ist nicht installiert (rund 2 GB).") + pack
    }

    var body: some View {
        VXBox(title: vxT("Game language", "Sprache des Spiels")) {
            VXRow(title: vxT("Game language", "Sprache des Spiels"), help: "language") {
                Picker(vxT("Game language", "Sprache des Spiels"), selection: $settings.gameLanguage) {
                    ForEach([VXGameLanguage.auto] + VXGameLanguage.named) { Text($0.ownName).tag($0) }
                }.pickerStyle(.menu).labelsHidden()
            }
            Text(languageNote).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        VXBox(title: vxT("Graphics quality", "Grafikqualität")) {
            VXRow(title: vxT("Graphics quality", "Grafikqualität"), help: "graphics", stacked: true) {
                Picker(vxT("Graphics quality", "Grafikqualität"), selection: $settings.graphics) {
                    Text("Standard").tag(VXGraphics.standard)
                    Text(vxT("Low", "Niedrig")).tag(VXGraphics.low)
                    Text(vxT("Medium", "Mittel")).tag(VXGraphics.medium)
                    Text(vxT("High", "Hoch")).tag(VXGraphics.high)
                }.pickerStyle(.segmented).labelsHidden()
            }
        }
    }
}

struct VXTurnMovePage: View {
    @ObservedObject private var settings = VXSettings.shared
    private static var gameDefault: String { vxT("Game default", "Wie im Spiel") }
    var body: some View {
        VXBox(title: vxT("Turning", "Drehen")) {
            VXRow(title: vxT("Turning", "Drehen"), help: "controls", stacked: true) {
                Picker(vxT("Turning", "Drehen"), selection: $settings.turn) {
                    Text(Self.gameDefault).tag(VXTurn.game)
                    Text(vxT("Snap", "In Schritten")).tag(VXTurn.snap)
                    Text(vxT("Smooth", "Fließend")).tag(VXTurn.smooth)
                }.pickerStyle(.segmented).labelsHidden()
            }
            Toggle(vxT("Snap angle: game default", "Schrittwinkel: wie im Spiel"),
                   isOn: Binding(get: { settings.snapAngle == nil }, set: { settings.snapAngle = $0 ? nil : VXSettings.snapAngleBuiltIn })).vxHelp("controls")
            if let a = settings.snapAngle {
                HStack {
                    Slider(value: Binding(get: { a }, set: { settings.snapAngle = $0 }), in: VXSettings.snapAngleRange, step: 5)
                    Text(String(format: "%.0f°", a)).monospacedDigit().frame(width: 70)
                }
            }
            Toggle(vxT("Turn speed: game default", "Drehgeschwindigkeit: wie im Spiel"),
                   isOn: Binding(get: { settings.turnSpeed == nil }, set: { settings.turnSpeed = $0 ? nil : VXSettings.turnSpeedBuiltIn })).vxHelp("controls")
            if let v = settings.turnSpeed {
                HStack {
                    Slider(value: Binding(get: { v }, set: { settings.turnSpeed = $0 }), in: VXSettings.turnSpeedRange, step: 0.1)
                    Text(String(format: "%.1f", v)).monospacedDigit().frame(width: 70)
                }
            }
        }
        VXBox(title: vxT("Movement", "Bewegung")) {
            VXRow(title: vxT("Movement", "Bewegung"), help: "controls", stacked: true) {
                Picker(vxT("Movement", "Bewegung"), selection: $settings.move) {
                    Text(Self.gameDefault).tag(VXMove.game)
                    Text(vxT("Teleport", "Teleport")).tag(VXMove.teleport)
                    Text(vxT("Walk", "Gehen")).tag(VXMove.walk)
                }.pickerStyle(.segmented).labelsHidden()
            }
        }
    }
}

struct VXIniPage: View {
    let group: VXIniSetting.Group
    @ObservedObject private var settings = VXSettings.shared
    private static var gameDefault: String { vxT("Game default", "Wie im Spiel") }
    var body: some View {
        VXBox(title: group.title) {
            ForEach(VXIniSetting.all.filter { $0.group == group }) { item in iniRow(item) }
            if group == .body || group == .teleport {
                Text(vxT("The number ranges are cautious bounds, not the game's own.", "Die Zahlenbereiche sind vorsichtige Grenzen, nicht die des Spiels."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        Label(vxT("\"Game default\" changes nothing: the game keeps its own value. Everything here applies the next time you start the game.",
                  "„Wie im Spiel“ ändert nichts: Das Spiel behält seinen eigenen Wert. Alles hier gilt beim nächsten Start des Spiels."),
              systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private func iniRow(_ item: VXIniSetting) -> some View {
        switch item.kind {
        case .flag:
            VXRow(title: item.localizedTitle, help: "game") {
                Picker(item.localizedTitle, selection: Binding(get: { settings.flag(item.id) }, set: { settings.setFlag(item.id, $0) })) {
                    Text(Self.gameDefault).tag(Bool?.none)
                    Text(vxT("On", "An")).tag(Bool?.some(true))
                    Text(vxT("Off", "Aus")).tag(Bool?.some(false))
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            }
        case .number(let range, let step, let unit):
            VStack(alignment: .leading) {
                Toggle(vxT("\(item.localizedTitle): game default", "\(item.localizedTitle): wie im Spiel"),
                       isOn: Binding(get: { settings.number(item.id) == nil },
                                     set: { settings.setNumber(item.id, $0 ? nil : (range.lowerBound + range.upperBound) / 2) }))
                if let v = settings.number(item.id) {
                    HStack {
                        Slider(value: Binding(get: { v }, set: { settings.setNumber(item.id, $0) }), in: range, step: step)
                        Text(String(format: "%g%@", v, unit)).monospacedDigit().frame(width: 70)
                    }
                }
            }.vxHelp("game")
        }
    }
}

// MARK: - Advanced and diagnostics

struct VXAdvancedPage: View {
    @ObservedObject private var settings = VXSettings.shared
    @State private var sense = VXSenseValues.load()
    private func note(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }

    var body: some View {
        VXBox(title: vxT("Picture in detail", "Bild im Detail")) {
            Toggle(vxT("Sharpening off", "Nachschärfen aus"), isOn: Binding(get: { settings.sharpen == nil }, set: { settings.sharpen = $0 ? nil : 0.35 }))
            if let v = settings.sharpen {
                HStack {
                    Text(vxT("Sharpening", "Nachschärfen"))
                    Slider(value: Binding(get: { v }, set: { settings.sharpen = $0 }), in: VXSettings.unitRange, step: 0.05)
                    Text(String(format: "%.2f", v)).monospacedDigit().frame(width: 70)
                }
            }
            note(vxT("A light sharpening pass on the final picture. Off by default; about 0.35 is a start.",
                     "Ein leichtes Nachschärfen des fertigen Bildes. Üblicherweise aus; etwa 0,35 ist ein Anfang."))
            Toggle(vxT("High-resolution display", "Hochauflösende Anzeige"), isOn: $settings.foveation)
            note(vxT("How the finished picture is handed to the headset: at full sharpness where you look, as every other AVP Play game does it. Off, the headset takes only a plain picture of about 2000 pixels an eye. Turn it off only if the picture looks warped or the game does not start.",
                     "Wie das fertige Bild an das Headset übergeben wird: in voller Schärfe dort, wohin du schaust, so wie bei jedem anderen AVP-Play-Spiel. Aus nimmt das Headset nur ein einfaches Bild von rund 2000 Pixeln je Auge an. Nur ausschalten, wenn das Bild verzerrt aussieht oder das Spiel nicht startet."))
        }
        VXBox(title: vxT("Controller alignment", "Controller-Ausrichtung")) {
            senseSlider(vxT("Pitch", "Neigung"), $sense.pitch, -45...45, 0.5, "°")
            senseSlider(vxT("Yaw", "Drehung"), $sense.yaw, -45...45, 0.5, "°")
            senseSlider(vxT("Roll", "Rollen"), $sense.roll, -45...45, 0.5, "°")
            senseSlider(vxT("Forward", "Vor"), Binding(get: { -sense.pos.z * 100 }, set: { sense.pos.z = -$0 / 100 }), -12...12, 0.5, " cm")
            senseSlider(vxT("Up", "Hoch"), Binding(get: { sense.pos.y * 100 }, set: { sense.pos.y = $0 / 100 }), -12...12, 0.5, " cm")
            senseSlider(vxT("Right", "Rechts"), Binding(get: { sense.pos.x * 100 }, set: { sense.pos.x = $0 / 100 }), -12...12, 0.5, " cm")
            HStack {
                Button(vxT("Reset", "Zurücksetzen")) { sense = VXSenseValues(); VXSenseValues.reset() }
                Text(sense.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            note(vxT("Rotates and moves the controller the game draws against your Sense controller. Applies to a running game within a second.",
                     "Dreht und verschiebt den Controller, den das Spiel zeichnet, gegen deinen Sense-Controller. Gilt im laufenden Spiel innerhalb einer Sekunde."))
        }
        VXBox(title: vxT("Head prediction", "Kopf-Vorhersage")) {
            Toggle(vxT("Automatic", "Automatisch"), isOn: Binding(get: { settings.predictMs == nil }, set: { settings.predictMs = $0 ? nil : 60 }))
            if let p = settings.predictMs {
                HStack {
                    Slider(value: Binding(get: { p }, set: { settings.predictMs = $0 }), in: VXSettings.predictRange, step: 5)
                    Text(String(format: "%.0f ms", p)).monospacedDigit().frame(width: 80)
                }
            }
            note(vxT("How far ahead the game's head position is predicted. Automatic follows the measured delay of the game's pictures; a fixed value is for experiments. Applies the next time you start.",
                     "Wie weit die Kopfposition für das Spiel vorausgesagt wird. Automatisch folgt der gemessenen Verzögerung der Bilder; ein fester Wert ist für Versuche. Gilt beim nächsten Start."))
        }
        VXBox(title: vxT("Eye height above the floor", "Augenhöhe über dem Boden")) {
            Toggle(vxT("Default (1.6 m)", "Standard (1,6 m)"), isOn: Binding(get: { settings.stageEyeHeight == nil }, set: { settings.stageEyeHeight = $0 ? nil : 1.6 }))
            if let h = settings.stageEyeHeight {
                HStack {
                    Slider(value: Binding(get: { h }, set: { settings.stageEyeHeight = $0 }), in: VXSettings.eyeHeightRange, step: 0.05)
                    Text(String(format: "%.2f m", h)).monospacedDigit().frame(width: 80)
                }
            }
            note(vxT("The height of your eyes above the floor that the game assumes, which sets where the floor is. Seated play wants a lower value. Applies the next time you start.",
                     "Die Höhe deiner Augen über dem Boden, von der das Spiel ausgeht; sie bestimmt, wo der Boden liegt. Im Sitzen passt ein kleinerer Wert. Gilt beim nächsten Start."))
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

struct VXDiagnosticsPage: View {
    var body: some View {
        VXBox(title: vxT("Logs", "Protokolle")) {
            let docs = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
            ForEach(["vxrt.log", "host_log.jsonl"], id: \.self) { name in
                let path = (docs as NSString).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: path) {
                    ShareLink(item: URL(fileURLWithPath: path)) { Label(vxT("Export \(name)", "\(name) exportieren"), systemImage: "square.and.arrow.up") }
                } else {
                    Text(vxT("\(name): not written yet", "\(name): noch nicht geschrieben")).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
