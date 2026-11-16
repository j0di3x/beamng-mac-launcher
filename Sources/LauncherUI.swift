// The launcher window: a sidebar (pages, game status, runtime) and a main pane of cards.
import SwiftUI
import AppKit

// MARK: - look

enum Theme {
    /// A colour with a dark and a light variant (follows the system appearance).
    static func dynamic(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
    static let main = dynamic(rgb(30, 31, 34), rgb(245, 245, 247))
    static let sidebar = dynamic(rgb(24, 25, 27), rgb(234, 234, 237))
    static let card = dynamic(rgb(37, 38, 42), rgb(255, 255, 255))
    static let stroke = dynamic(NSColor(white: 1, alpha: 0.07), NSColor(white: 0, alpha: 0.08))
    static let chip = dynamic(NSColor(white: 1, alpha: 0.07), NSColor(white: 0, alpha: 0.06))
    static let selection = dynamic(NSColor(white: 1, alpha: 0.08), NSColor(white: 0, alpha: 0.07))
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            // fills its grid cell, so cards side by side are the same height
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: AnyView? = nil
    init(_ t: String, trailing: AnyView? = nil) { text = t; self.trailing = trailing }
    var body: some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 2)
    }
}

/// Title and an optional explanation on the left, a control on the right.
struct SettingRow<Accessory: View>: View {
    let title: String
    var detail = ""
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty { Caption(detail) }
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

/// A small label above a control, as in a form grid.
struct Field<Content: View>: View {
    let label: String
    var note = ""
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                if !note.isEmpty { Text("·  " + note).font(.caption).foregroundStyle(.tertiary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .orange
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.55)))
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.chip))
    }
}

struct SwitchToggle: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }
}

// MARK: - window

struct ContentView: View {
    @EnvironmentObject var m: Launcher
    @AppStorage("showAdvanced") var showAdvanced = false
    @State private var launcherLanguage = Languages.launcherOverride
    // `-startPage advanced` opens on that page (for README screenshots)
    @State private var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "startPage") ?? "") ?? .play

    enum Page: String, CaseIterable, Identifiable {
        case play, graphics, controllers, language, advanced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .play: return L("Play")
            case .graphics: return L("Graphics")
            case .controllers: return L("Controllers")
            case .language: return L("Language")
            case .advanced: return L("Advanced")
            }
        }
        var icon: String {
            switch self {
            case .play: return "play.fill"
            case .graphics: return "display"
            case .controllers: return "gamecontroller"
            case .language: return "globe"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    static let titleBarHeight: CGFloat = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        return w.frame.height - w.contentLayoutRect.height
    }()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.stroke).frame(width: 1)
            VStack(spacing: 0) {
                if page == .advanced { advancedPage } else { overviewPage }
                statusBar
            }
            .background(Theme.main)
        }
        // 600 tall in all: the content also fills the (hidden) title bar, which macOS adds on top
        .frame(width: 980, height: 600)
        .frame(width: 980, height: 600 - Self.titleBarHeight, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BeamNG.drive").font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(stateColor).frame(width: 6, height: 6)
                        Text(stateLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 52).padding(.horizontal, 16).padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(Page.allCases) { p in
                    Button { go(p) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.icon).frame(width: 18)
                                .foregroundStyle(page == p ? Color.accentColor : .secondary)
                            Text(p.title).font(.system(size: 13, weight: page == p ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(page == p ? Theme.selection : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
            .padding(.horizontal, 10)

            if m.state != .stopped && (m.conf.beammp || m.conf.earth) {
                VStack(alignment: .leading, spacing: 6) {
                    if m.conf.beammp { helperBadge("BeamMP", m.beammpRunning) }
                    if m.conf.earth { helperBadge("BeamNG.Earth", m.earthRunning) }
                }
                .padding(.horizontal, 18).padding(.top, 18)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Runtime").uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Chip(text: "GPTK \(m.currentGPTK.isEmpty ? "—" : m.currentGPTK)")
                    if m.conf.metal4 { Chip(text: "Metal 4") }
                    Chip(text: Launcher.rendererShort(m.conf.renderer))
                }
            }
            .padding(16)
        }
        .frame(width: 228)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    var stateColor: Color { m.state == .running ? .green : (m.state == .starting ? .orange : .gray) }
    var stateLabel: String { m.state == .running ? L("Running") : (m.state == .starting ? L("Starting…") : L("Not running")) }

    func helperBadge(_ name: String, _ on: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
        .help(on ? L("Running") : L("Starting…"))
    }

    func go(_ p: Page) { page = p }

    // MARK: tabs (Play, Graphics, Controllers + Language)

    var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !m.setupComplete { setupCard }
                if !m.pendingChanges.isEmpty { pendingBanner }
                switch page {
                case .play:
                    VStack(alignment: .leading, spacing: 8) { SectionTitle(L("Play")); playCard }
                case .graphics:
                    VStack(alignment: .leading, spacing: 8) { SectionTitle(L("Graphics")); graphicsCard }
                default:
                    // Controllers and Language share one tab, side by side, cards the same height
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            SectionTitle(L("Controllers"), trailing: AnyView(
                                Button { m.refreshDevices() } label: { Image(systemName: "arrow.clockwise").font(.caption) }
                                    .buttonStyle(.borderless).help(L("Scan again"))))
                            SectionTitle(L("Language"))
                        }
                        GridRow {
                            controllersCard
                            languageCard
                        }
                    }
                }
            }
            .padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 24)
        }
    }

    var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(headline).font(.system(size: 25, weight: .bold))
                Text(summary).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if m.state == .stopped {
                Button { m.play() } label: {
                    Label(L("Play"), systemImage: "play.fill").font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .shadow(color: .accentColor.opacity(0.45), radius: 12, y: 3)
                .disabled(!m.setupComplete || m.busy || m.downloading)
                .keyboardShortcut(.defaultAction)
            } else {
                HStack(spacing: 8) {
                    Button { m.restart() } label: { Label(L("Restart"), systemImage: "arrow.clockwise") }
                        .controlSize(.large).disabled(m.busy)
                    Button(role: .destructive) { m.quitGame() } label: { Label(L("Quit"), systemImage: "stop.fill") }
                        .controlSize(.large).disabled(m.busy)
                }
            }
        }
    }

    var headline: String {
        if !m.setupComplete { return L("Almost ready") }
        switch m.state {
        case .running: return L("Driving")
        case .starting: return L("Starting…")
        default: return L("Ready to drive")
        }
    }

    var summary: String {
        let mode = m.conf.beammp ? L("Multiplayer (BeamMP)") : L("Single player")
        let preset = L(m.preset)
        return [mode, preset, Launcher.rendererLong(m.conf.renderer)].joined(separator: "  ·  ")
    }

    var pendingBanner: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
            Text(L("Changes wait until the game restarts.")).font(.callout)
            Spacer()
            Button(L("Apply & Restart")) { m.restart() }.disabled(m.busy)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }

    var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(L("Setup"))
            Card {
                HStack {
                    CheckRow(ok: m.wineOK && m.prefixOK, title: L("Wine runtime"),
                             detail: m.wineOK && m.prefixOK ? L("Installed") : L("Imported from GameHub (install it and run any game once)"))
                    Spacer()
                    Button(L("Import from GameHub")) { m.importRuntime() }.disabled(m.busy)
                }
                Divider()
                HStack {
                    CheckRow(ok: m.gptkOK, title: L("Apple Game Porting Toolkit"),
                             detail: m.gptkOK ? m.currentGPTK : L("Download \"Evaluation environment for Windows games\" from Apple"))
                    Spacer()
                    Button(L("Get from Apple")) { m.open(URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!) }
                    Button(L("Install .dmg…")) { m.installGPTK() }.disabled(m.busy)
                }
                Divider()
                HStack {
                    CheckRow(ok: m.gameDirOK, title: L("BeamNG.drive folder"), detail: m.gameDirOK ? m.conf.gameDir : L("Not chosen"))
                    Spacer()
                    Button(L("Choose…")) { m.chooseGameDir() }
                }
            }
        }
    }

    // MARK: play card

    func updateBadge(_ addon: String, _ action: @escaping () -> Void) -> some View {
        Group {
            if m.updates.contains(addon) {
                Button(L("Update")) { action() }.controlSize(.small).tint(.orange).disabled(m.downloading)
            }
        }
    }

    func moreMenu<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        Menu { items() } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26).background(Circle().fill(Theme.chip))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    var playCard: some View {
        Card {
            HStack {
                Picker("", selection: Binding(get: { m.conf.beammp }, set: { m.setMultiplayer($0) })) {
                    Text(L("Single player")).tag(false)
                    Text(L("Multiplayer (BeamMP)")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().disabled(m.downloading)
                Spacer()
                if m.beammpInstalled {
                    moreMenu {
                        Button(L("Update BeamMP")) { m.installBeamMP() }
                        Button(L("Open BeamMP log")) { m.open(Paths.logs.appendingPathComponent("beammp.log")) }
                        Button(L("BeamMP website")) { m.open(URL(string: "https://beammp.com")!) }
                        Divider()
                        Button(L("Remove BeamMP")) { m.removeAddon("beammp") }
                    }
                }
            }
            if m.conf.beammp {
                Caption(L("BeamMP %@ starts before the game. In the game, open Multiplayer and pick a server.", m.addonVersions["beammp"] ?? ""))
            } else if !m.beammpInstalled {
                Caption(L("Multiplayer downloads the official BeamMP launcher (about 8 MB) from GitHub."))
            }
            Divider()
            HStack(spacing: 8) {
                Text(L("Real-world maps")).font(.system(size: 13, weight: .semibold))
                Pill(text: L("experimental"))
            }
            SettingRow(title: "BeamNG.Earth" + (m.addonVersions["earth"].map { "  \($0)" } ?? ""),
                       detail: m.earthInstalled
                        ? L("The whole planet, streamed from satellite and map data while you drive. In the game: Freeroam → BeamNG.Earth.")
                        : L("The whole planet, streamed from satellite and map data while you drive. About 90 MB; needs internet.")) {
                HStack(spacing: 8) {
                    updateBadge("earth") { m.installEarth() }
                    if m.earthInstalled {
                        moreMenu {
                            Button(L("Update BeamNG.Earth")) { m.installEarth() }
                            Button(L("Open BeamNG.Earth log")) { m.open(Paths.prefix.appendingPathComponent("drive_c/users/steamuser/AppData/Local/beamng-earth/logs/server.log")) }
                            Button(L("Project page")) { m.open(URL(string: "https://github.com/TecnaGamer/BeamNG.Earth")!) }
                            Divider()
                            Button(L("Remove BeamNG.Earth")) { m.removeAddon("earth") }
                        }
                    }
                    SwitchToggle(isOn: Binding(get: { m.conf.earth }, set: { m.setEarth($0) })).disabled(m.downloading)
                }
            }
            SettingRow(title: "EarthNG", detail: earthngDetail) {
                if m.earthngInstalled {
                    HStack(spacing: 8) {
                        updateBadge("earthng") { m.installEarthNG() }
                        moreMenu {
                            Button(L("Get the Albania map (226 MB)")) { m.installEarthNGAlbania() }
                            Button(L("Add map pack…")) { m.addEarthNGPack() }
                            Button(L("More maps")) { m.open(URL(string: "https://github.com/Alezx311/earthng#install-and-play")!) }
                            Divider()
                            Button(L("Update EarthNG")) { m.installEarthNG() }
                            Button(L("Remove EarthNG and its maps")) { m.removeAddon("earthng") }
                        }
                    }
                } else {
                    Button(L("Install")) { m.installEarthNG() }.disabled(m.downloading)
                }
            }
            Divider()
            SettingRow(title: L("Show in Discord status"),
                       detail: m.conf.discord && !m.discordRunning
                        ? L("Discord isn't open. Your status appears once it is.")
                        : L("Friends see your map and car while you play.")) {
                SwitchToggle(isOn: Binding(get: { m.conf.discord }, set: { m.setDiscord($0) }))
            }
        }
    }

    var earthngDetail: String {
        if !m.earthngInstalled {
            return L("Real towns built from OpenStreetMap inside the game, no extra app running. About 280 MB plus a map pack.")
        }
        return m.earthngPacks.isEmpty ? L("No map pack yet: get Albania or add one from the … menu.")
                                      : L("Maps: %@. In the game: Freeroam → EarthNG - Planet.", m.earthngPacks.joined(separator: ", "))
    }

    // MARK: graphics card

    var graphicsCard: some View {
        Card {
            HStack(spacing: 12) {
                Text(L("Preset")).font(.system(size: 13, weight: .medium))
                Picker("", selection: Binding(get: { m.preset }, set: { m.applyPreset($0) })) {
                    ForEach(m.presetNames, id: \.self) { Text(L($0)).tag($0) }
                    if !m.presetNames.contains(m.preset) && m.preset != "Potato" { Text(L(m.preset)).tag(m.preset) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text(L("Potato mode")).font(.callout).foregroundStyle(.secondary)
                SwitchToggle(isOn: Binding(get: { m.preset == "Potato" }, set: { m.applyPreset($0 ? "Potato" : "Lowest") }))
            }
            if m.preset == "Potato" {
                Caption(L("Potato: below Lowest. Half resolution, 30 FPS cap, every effect off and no parked cars. For older or 8 GB Macs. Small maps like Gridmap or Small Island run best."))
            }
            Divider()
            Grid(alignment: .topLeading, horizontalSpacing: 22, verticalSpacing: 16) {
                if showAdvanced {
                    GridRow {
                        Field(label: L("Anti-aliasing")) {
                            PopUp(selection: Binding(get: { m.aaType }, set: { m.setAA($0) }), options: aaOptions)
                        }
                        Field(label: L("Sharpness"), note: m.aaType == "fsr3" ? "" : L("works with FSR 3")) {
                            HStack {
                                Slider(value: $m.sharpness, in: 0...1, step: 0.05) { editing in
                                    if !editing { m.change(["GraphicUpscalingSharpness": (m.sharpness * 100).rounded() / 100]) }
                                }
                                Text("\(Int((m.sharpness * 100).rounded()))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                            .disabled(m.aaType != "fsr3")
                        }
                    }
                    GridRow {
                        Field(label: L("Shadows")) {
                            PopUp(selection: Binding(get: { m.shadows }, set: { m.shadows = $0; m.setDetail("GraphicShadowsQuality", $0) }), options: ["Disabled", "Lowest", "Low", "Normal", "High", "Ultra"].map { ($0, L($0)) })
                        }
                        Field(label: L("Meshes")) {
                            PopUp(selection: Binding(get: { m.meshes }, set: { m.meshes = $0; m.setDetail("GraphicMeshQuality", $0) }), options: ["Lowest", "Low", "Normal", "High", "Ultra"].map { ($0, L($0)) })
                        }
                    }
                }
                GridRow {
                    Field(label: L("Display")) {
                        PopUp(selection: Binding(get: { m.displayMode }, set: { m.setDisplayMode($0) }), options: [("Window", L("Window")), ("Borderless", L("Full screen (borderless)")), ("Fullscreen", L("Full screen (exclusive)")), ("Span", L("Span all displays"))])
                    }
                    if m.displayMode == "Window" {
                        Field(label: L("Window size")) {
                            PopUp(selection: Binding(get: { m.windowRes }, set: { m.setWindow($0) }), options: m.windowChoices)
                        }
                    } else if m.displayMode == "Span" {
                        Field(label: L("Span all displays")) { spanNote }
                    } else {
                        Field(label: L("Window size")) { Caption(L("Full screen covers the Dock and menu bar while you play.")) }
                    }
                }
                GridRow {
                    Field(label: L("Resolution scale"), note: m.renderScale < 0.99 || m.aaType == "fsr3" ? m.renderResolution : L("lower for more FPS")) {
                        HStack {
                            Slider(value: $m.renderScale, in: 0.5...1.0, step: 0.05) { editing in
                                if !editing { m.setRenderScale(m.renderScale) }
                            }
                            Text("\(Int((m.renderScale * 100).rounded()))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    Field(label: L("Renderer")) {
                        PopUp(selection: Binding(get: { m.conf.renderer }, set: { m.setRenderer($0) }), options: Launcher.renderers.map { ($0.id, $0.name) }).disabled(m.downloading)
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Pill(text: L("pre-release"))
                Caption(rendererNote)
                Spacer(minLength: 12)
                Text(L("Show FPS counter")).font(.callout)
                SwitchToggle(isOn: Binding(get: { m.conf.fpsHUD }, set: {
                    m.conf.fpsHUD = $0; m.conf.save()
                    m.message = $0 ? L("FPS counter on from the next start.") : L("FPS counter off from the next start.")
                }))
            }
        }
    }

    @ViewBuilder var spanNote: some View {
        let _ = m.screensTick
        if NSScreen.screens.count < 2 {
            Caption(L("Only one display is connected. Connect another and the game window covers both; until then it fills this one."))
        } else if !Launcher.displaysShareSpace {
            VStack(alignment: .leading, spacing: 6) {
                Caption(L("macOS keeps each window on one display while “Displays have separate Spaces” is on. Turn it off in Desktop & Dock (near the bottom, under Mission Control), then log out and back in."))
                Button(L("Open Desktop & Dock Settings")) { Launcher.openSpacesSetting() }.controlSize(.small)
            }
        } else if let a = Launcher.spanArea() {
            Caption(L("The game window covers %ld displays: %ld × %ld.", NSScreen.screens.count, a.w, a.h))
        }
    }

    var rendererNote: String {
        switch m.conf.renderer {
        case "d3d11": return L("The game's DirectX 11 renderer on Apple D3DMetal. Older and simpler; some effects look different.")
        case "dxvk": return m.dxvkInstalled
            ? L("DirectX 11 translated to Vulkan by DXVK, then to Metal by MoltenVK. The first drive stutters while shaders build.")
            : L("Downloads DXVK (2.8 MB) the first time.")
        case "vulkan": return L("BeamNG's own Vulkan renderer on MoltenVK. Experimental: with the current Wine it crashes at start; switch back if it does.")
        default: return L("The game's default DirectX 12 renderer on Apple D3DMetal. Best tested.")
        }
    }

    var aaOptions: [(String, String)] {
        var o = [("off", L("Off")), ("fxaa", "FXAA"), ("smaa", "SMAA"), ("smaaT2x", "SMAA T2x"), ("fsr3", L("FSR 3 (best)"))]
        if !o.contains(where: { $0.0 == m.aaType }) { o.append((m.aaType, m.aaType)) }
        return o
    }
    var gameLanguageOptions: [(String, String)] {
        var o = [("", L("Automatic"))] + m.gameLanguages.map { ($0, Languages.name($0)) }
        if !m.gameLanguage.isEmpty && !m.gameLanguages.contains(m.gameLanguage) { o.append((m.gameLanguage, m.gameLanguage)) }
        return o
    }
    var launcherLanguageOptions: [(String, String)] {
        [("", L("Same as macOS"))] + m.gameLanguages.compactMap { k in Languages.launcherCode[k].map { ($0, Languages.name(k)) } }
    }

    // MARK: controllers and language

    var controllersCard: some View {
        Card {
            let pads = m.devices.filter { $0.kind != .wheel }
            let wheels = m.devices.filter { $0.kind == .wheel }
            deviceLine(ok: !pads.isEmpty, title: pads.isEmpty ? L("No controller connected") : L("Controller detected"),
                       items: pads.map { "\($0.name) · \(L($0.connection))" })
            deviceLine(ok: !wheels.isEmpty, title: wheels.isEmpty ? L("No steering wheel connected") : L("Steering wheel detected"),
                       items: wheels.map { "\($0.name) · \(L($0.connection))" })
            if !m.seenByGame.isEmpty {
                Caption(L("BeamNG saw last time: %@", m.seenByGame.joined(separator: ", ")))
            }
        }
    }

    func deviceLine(ok: Bool, title: String, items: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle().fill(ok ? Color.green : Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                ForEach(items, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    var languageCard: some View {
        Card {
            Field(label: L("Game")) {
                PopUp(selection: Binding(get: { m.gameLanguage }, set: { m.setGameLanguage($0) }), options: gameLanguageOptions)
            }
            Field(label: L("Launcher")) {
                PopUp(selection: Binding(get: { launcherLanguage }, set: { launcherLanguage = $0; m.setLauncherLanguage($0) }), options: launcherLanguageOptions)
            }
        }
    }

    // MARK: advanced page

    var advancedPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("Advanced")).font(.system(size: 25, weight: .bold))
                        Text(L("Compatibility switches and maintenance tools")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 10) {
                            Text(L("Enable advanced settings")).font(.callout).foregroundStyle(.secondary)
                            SwitchToggle(isOn: $showAdvanced.animation(.easeInOut(duration: 0.2)))
                        }
                        Text(L("Adds anti-aliasing, sharpness, shadows and meshes to Graphics.")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(L("Compatibility"))
                    Card {
                        SettingRow(title: L("Fix missing trees and objects"),
                                   detail: L("-nogfxgpudriven · needed until Apple fixes GPU-driven drawing; costs some FPS")) {
                            SwitchToggle(isOn: Binding(get: { m.conf.fixTrees }, set: { m.conf.fixTrees = $0; m.conf.save() }))
                        }
                        Divider()
                        SettingRow(title: "Metal 4", detail: L("Needed for shadows")) {
                            SwitchToggle(isOn: Binding(get: { m.conf.metal4 }, set: { m.conf.metal4 = $0; m.conf.save() }))
                        }
                        Divider()
                        SettingRow(title: L("Disable fog (noFogFix mod)"), detail: L("Only needed on GPTK 3 — GPTK 4 draws fog correctly")) {
                            SwitchToggle(isOn: Binding(get: { m.fogFix }, set: { m.setFogFix($0) }))
                        }
                        Divider()
                        SettingRow(title: L("GPTK version")) {
                            HStack(spacing: 8) {
                                Picker("", selection: Binding(get: { m.currentGPTK }, set: { m.selectGPTK($0) })) {
                                    ForEach(m.gptkVersions, id: \.self) { Text($0).tag($0) }
                                }.labelsHidden().frame(width: 110).disabled(m.gptkVersions.isEmpty)
                                Button(L("Install .dmg…")) { m.installGPTK() }.disabled(m.busy)
                            }
                        }
                        Field(label: L("Extra launch options")) {
                            TextField(L("e.g. -console"), text: Binding(get: { m.conf.extraArgs }, set: { m.conf.extraArgs = $0; m.conf.save() }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(L("Tools"))
                    Card {
                        HStack(spacing: 8) {
                            Button(L("Clear shader cache")) { m.clearShaderCache() }
                            Button(L("Game folder…")) { m.chooseGameDir() }
                            Button(L("Open mods folder")) { m.open(Paths.mods) }
                            Button(L("Open game log")) { m.open(Paths.gameLog) }
                        }
                        Divider()
                        HStack(spacing: 12) {
                            Button(role: .destructive) { confirmReset() } label: { Text(L("Reset to defaults")).foregroundStyle(.red) }
                            Text(m.conf.gameDir.isEmpty ? L("No game folder chosen") : m.conf.gameDir)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 24)
        }
    }

    func confirmReset() {
        let a = NSAlert()
        a.messageText = L("Reset to recommended settings?")
        a.informativeText = L("High preset, full resolution with FSR 3, windowed, tree fix and Metal 4 on, fog fix off. Your current game settings are backed up first.")
        a.addButton(withTitle: L("Reset")); a.addButton(withTitle: L("Cancel"))
        if a.runModal() == .alertFirstButtonReturn { m.resetDefaults() }
    }

    // MARK: status bar (downloads and messages)

    @ViewBuilder var statusBar: some View {
        if m.downloading {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 10) {
                Text(L("Downloading %@…", m.downloadTitle)).font(.caption).lineLimit(1)
                ProgressView(value: m.downloadFraction).frame(maxWidth: .infinity)
                Text("\(Int(m.downloadFraction * 100))%").font(.caption).monospacedDigit()
                Button(L("Cancel")) { m.cancelDownload() }.controlSize(.small)
            }
            .padding(.horizontal, 30).padding(.vertical, 9)
        } else if !m.message.isEmpty {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack {
                if m.busy { ProgressView().controlSize(.small) }
                Text(m.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
            }
            .padding(.horizontal, 30).padding(.vertical, 9)
        }
    }
}

/// The native macOS pop-up button. Unlike SwiftUI's Picker it stretches to the width it's given.
struct PopUp<V: Hashable>: NSViewRepresentable {
    @Binding var selection: V
    let options: [(V, String)]

    func makeNSView(context: Context) -> NSPopUpButton {
        let b = NSPopUpButton(frame: .zero, pullsDown: false)
        b.target = context.coordinator
        b.action = #selector(Coordinator.changed(_:))
        b.setContentHuggingPriority(.defaultLow, for: .horizontal)
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return b
    }

    func updateNSView(_ b: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(\.1)
        if b.itemTitles != titles {
            b.removeAllItems()
            for t in titles { b.menu?.addItem(NSMenuItem(title: t, action: nil, keyEquivalent: "")) }
        }
        if let i = options.firstIndex(where: { $0.0 == selection }) { b.selectItem(at: i) }
        b.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUp
        init(_ p: PopUp) { parent = p }
        @objc func changed(_ b: NSPopUpButton) {
            let i = b.indexOfSelectedItem
            guard parent.options.indices.contains(i) else { return }
            parent.selection = parent.options[i].0
        }
    }
}
