// BeamNG Launcher — runs BeamNG.drive on macOS through Wine + Apple D3DMetal (GPTK).
// Build: see build.sh next to this file.
import SwiftUI
import AppKit
import IOKit
import IOKit.hid
import GameController

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let root = home.appendingPathComponent("Library/Application Support/BeamNG-GPTK4")
    static let conf = root.appendingPathComponent("launcher.conf")
    static let bin = root.appendingPathComponent("bin")
    static let gptk = root.appendingPathComponent("gptk")
    static let wineInstalls = root.appendingPathComponent("containers/wine_installations")
    static let prefix = root.appendingPathComponent("containers/prefixes/beamng")
    static let userRoot = prefix.appendingPathComponent("drive_c/users/steamuser/AppData/Local/BeamNG/BeamNG.drive/current")
    static let settings = userRoot.appendingPathComponent("settings/settings.json")
    static let gameLog = userRoot.appendingPathComponent("beamng.log")
    static let mods = userRoot.appendingPathComponent("mods")
    static let launchLog = root.appendingPathComponent("logs/last-launch.log")
    static var userCache: URL {
        var buf = [CChar](repeating: 0, count: 1024)
        confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        return URL(fileURLWithPath: String(cString: buf))
    }
}

// MARK: - Shell helper

@discardableResult
func runShell(_ script: URL, _ args: [String] = [], wait: Bool = true) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [script.path] + args
    let pipe = Pipe()
    if wait { p.standardOutput = pipe; p.standardError = pipe } else {
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    }
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    guard wait else { return (0, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func processRunning(_ pattern: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", pattern]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

// MARK: - launcher.conf

struct LauncherConfig {
    var gameDir = ""
    var fixTrees = true
    var extraArgs = ""
    var metal4 = true
    var fpsHUD = false
    var gptkVersion = "current"

    static func load() -> LauncherConfig {
        var c = LauncherConfig()
        guard let text = try? String(contentsOf: Paths.conf, encoding: .utf8) else { return c }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            val = val.replacingOccurrences(of: "$HOME", with: Paths.home.path)
            switch key {
            case "GAME_DIR": c.gameDir = val
            case "GAME_ARGS": c.fixTrees = val.contains("-nogfxgpudriven")
            case "EXTRA_ARGS": c.extraArgs = val
            case "METAL4": c.metal4 = val == "1"
            case "FPS_HUD": c.fpsHUD = val == "1"
            case "GPTK_VERSION": c.gptkVersion = val.isEmpty ? "current" : val
            default: break
            }
        }
        return c
    }

    func save() {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let text = """
        # BeamNG launcher settings (written by the launcher app)
        GAME_DIR=\(q(gameDir))
        GAME_ARGS=\(q(fixTrees ? "-nogfxgpudriven" : ""))
        EXTRA_ARGS=\(q(extraArgs))
        METAL4=\(metal4 ? 1 : 0)
        FPS_HUD=\(fpsHUD ? 1 : 0)
        GPTK_VERSION=\(q(gptkVersion))

        """
        try? FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
        try? text.write(to: Paths.conf, atomically: true, encoding: .utf8)
    }
}

// MARK: - BeamNG settings.json

enum GameSettingsFile {
    static func load() -> [String: Any] {
        guard let d = try? Data(contentsOf: Paths.settings),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }
    static func merge(_ changes: [String: Any]) {
        var s = load()
        for (k, v) in changes { s[k] = v }
        try? FileManager.default.createDirectory(at: Paths.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: Paths.settings, options: .atomic)
        }
    }
    static func backup(tag: String) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dst = Paths.settings.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(tag)-\(f.string(from: Date()))")
        try? FileManager.default.copyItem(at: Paths.settings, to: dst)
    }
}

/// Values BeamNG uses when a key is missing from settings.json (read from the game's defaults.json).
func gameDefaults(gameDir: String) -> [String: Any] {
    var out: [String: Any] = [
        "GraphicOverallQuality": "Normal", "GraphicUpscalingQuality": 1.0, "GraphicAntialiasType": "fxaa",
        "GraphicUpscalingSharpness": 0.25, "GraphicShadowsQuality": "Normal", "GraphicMeshQuality": "Normal",
        "GraphicDisplayResolutions": "1280 720", "GraphicAntialias": 4,
    ]
    let url = URL(fileURLWithPath: gameDir).appendingPathComponent("settings/defaults.json")
    if let d = try? Data(contentsOf: url),
       let obj = try? JSONSerialization.jsonObject(with: d, options: [.json5Allowed]) as? [String: Any] {
        for (k, v) in obj { if let arr = v as? [Any], arr.count >= 2 { out[k] = arr[1] } }
    }
    return out
}

func gamePresets(gameDir: String) -> [String: [String: Any]] {
    let url = URL(fileURLWithPath: gameDir).appendingPathComponent("lua/ge/extensions/core/settings/settingsPresets.json")
    guard let d = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] else { return [:] }
    return obj
}

// MARK: - Controllers

struct InputDevice: Identifiable, Hashable {
    enum Kind: String { case gamepad = "Controller", wheel = "Steering wheel", joystick = "Joystick" }
    var id: String
    var name: String
    var kind: Kind
    var connection: String
    var rawName = ""
}

enum ControllerScanner {
    static let wheelVendors: Set<Int> = [0x044f, 0x0eb7, 0x346e, 0x3416, 0x16d0, 0x1dd2, 0x0483]
    static let wheelWords = ["wheel", "racing", "driving force", "g29", "g920", "g923", "g27", "g25", "t300",
                             "t150", "t248", "tmx", "t-gt", "csl", "podium", "moza", "simucube", "fanatec"]
    static let knownNames: [String: String] = [
        "045e:028e": "Xbox 360 controller", "045e:028f": "Xbox 360 wireless controller",
        "045e:02ea": "Xbox One controller", "045e:0b12": "Xbox Series controller",
        "045e:0b13": "Xbox Series controller", "054c:0ce6": "DualSense controller", "054c:09cc": "DualShock 4 controller",
    ]

    static func classify(name: String, vendor: Int, usage: Int) -> InputDevice.Kind {
        let n = name.lowercased()
        if wheelVendors.contains(vendor) && vendor != 0x0483 { return .wheel }
        if wheelWords.contains(where: { n.contains($0) }) { return .wheel }
        if usage == kHIDUsage_GD_Joystick || usage == kHIDUsage_GD_MultiAxisController {
            return n.contains("pad") || n.contains("controller") ? .gamepad : .joystick
        }
        return .gamepad
    }

    static func displayName(_ raw: String, manufacturer: String, vendor: Int, product: Int) -> String {
        let key = String(format: "%04x:%04x", vendor, product)
        var base = knownNames[key] ?? raw
        let looksLikeCode = base.isEmpty || base.range(of: "^[0-9A-Fa-f]{5,}$", options: .regularExpression) != nil
        if looksLikeCode { base = "Game controller" }
        if !manufacturer.isEmpty && !base.lowercased().contains(manufacturer.lowercased()) && knownNames[key] != nil || looksLikeCode && !manufacturer.isEmpty {
            base += " (\(manufacturer))"
        }
        return base
    }

    static func scan() -> [InputDevice] {
        var found: [String: InputDevice] = [:]

        // 1. HID game controllers, joysticks and wheels
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let usages = [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController]
        let matches = usages.map { [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as [String: Any] }
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> {
            for d in devs {
                func prop(_ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }
                let name = prop(kIOHIDProductKey) as? String ?? ""
                let manu = prop(kIOHIDManufacturerKey) as? String ?? ""
                let v = prop(kIOHIDVendorIDKey) as? Int ?? 0
                let p = prop(kIOHIDProductIDKey) as? Int ?? 0
                let usage = prop(kIOHIDPrimaryUsageKey) as? Int ?? 0
                let transport = prop(kIOHIDTransportKey) as? String ?? "USB"
                let id = String(format: "%04x:%04x", v, p)
                found[id] = InputDevice(id: id, name: displayName(name, manufacturer: manu, vendor: v, product: p),
                                        kind: classify(name: name, vendor: v, usage: usage),
                                        connection: transport.lowercased().contains("bluetooth") ? "Bluetooth" : "USB",
                                        rawName: name)
            }
        }
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

        // 2. Wired Xbox-style (XInput) pads that are not HID devices
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iter) == KERN_SUCCESS {
            var svc = IOIteratorNext(iter)
            while svc != 0 {
                func num(_ e: io_registry_entry_t, _ k: String) -> Int? {
                    IORegistryEntryCreateCFProperty(e, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
                }
                func str(_ e: io_registry_entry_t, _ k: String) -> String? {
                    IORegistryEntryCreateCFProperty(e, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                }
                if num(svc, "bInterfaceClass") == 255 && num(svc, "bInterfaceSubClass") == 93 {
                    var parent: io_registry_entry_t = 0
                    if IORegistryEntryGetParentEntry(svc, kIOServicePlane, &parent) == KERN_SUCCESS {
                        let v = num(parent, "idVendor") ?? 0, p = num(parent, "idProduct") ?? 0
                        let id = String(format: "%04x:%04x", v, p)
                        if found[id] == nil {
                            let name = str(parent, "kUSBProductString") ?? str(parent, "USB Product Name") ?? ""
                            let manu = str(parent, "kUSBVendorString") ?? str(parent, "USB Vendor Name") ?? ""
                            found[id] = InputDevice(id: id, name: displayName(name, manufacturer: manu, vendor: v, product: p),
                                                    kind: classify(name: name, vendor: v, usage: kHIDUsage_GD_GamePad), connection: "USB",
                                                    rawName: name)
                        }
                        IOObjectRelease(parent)
                    }
                }
                IOObjectRelease(svc)
                svc = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }

        // 3. Controllers macOS knows through the Game Controller framework (Bluetooth pads)
        for gc in GCController.controllers() {
            let raw = gc.vendorName ?? ""
            let n = raw.lowercased()
            // the same pad is often already listed from USB/HID under its raw product name
            if found.values.contains(where: { !n.isEmpty && ($0.rawName.lowercased() == n || $0.name.lowercased().contains(n)) }) { continue }
            let name = displayName(raw, manufacturer: "", vendor: 0, product: 0)
            found["gc:\(raw)"] = InputDevice(id: "gc:\(raw)", name: name, kind: .gamepad, connection: "Wireless", rawName: raw)
        }
        return found.values.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    /// Devices BeamNG itself reported in its latest log.
    static func seenByGame() -> [String] {
        guard let text = try? String(contentsOf: Paths.gameLog, encoding: .utf8) else { return [] }
        var names: [String] = []
        for line in text.split(separator: "\n") where line.contains("Device connected:") {
            if let r = line.range(of: "Device connected: ") {
                let rest = line[r.upperBound...]
                let name = rest.components(separatedBy: " (").first ?? String(rest)
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }
}

// MARK: - Model

@MainActor
final class Launcher: ObservableObject {
    enum GameState { case stopped, starting, running }

    @Published var state: GameState = .stopped
    @Published var conf = LauncherConfig.load()
    @Published var message = ""
    @Published var busy = false

    // setup
    @Published var wineOK = false
    @Published var gptkVersions: [String] = []
    @Published var currentGPTK = ""
    @Published var prefixOK = false

    // graphics (mirror of settings.json)
    @Published var preset = "Normal"
    @Published var renderScale = 1.0
    @Published var aaType = "fxaa"
    @Published var sharpness = 0.25
    @Published var shadows = "Normal"
    @Published var meshes = "Normal"
    @Published var windowRes = "1280 720"
    @Published var pendingChanges: [String: Any] = [:]
    @Published var fogFix = false

    // input
    @Published var devices: [InputDevice] = []
    @Published var seenByGame: [String] = []

    private var timer: Timer?
    private var lastState: GameState = .stopped

    var gameDirOK: Bool { FileManager.default.fileExists(atPath: conf.gameDir + "/BeamNG.drive.exe") }
    var gptkOK: Bool { !currentGPTK.isEmpty }
    var setupComplete: Bool { wineOK && gptkOK && gameDirOK && prefixOK }
    var presetNames: [String] {
        let all = gamePresets(gameDir: conf.gameDir).keys
        return ["Lowest", "Low", "Normal", "High", "Ultra"].filter { all.contains($0) }
    }

    init() {
        installScripts()
        if conf.gameDir.isEmpty, let found = Launcher.findGameDir() { conf.gameDir = found; conf.save() }
        refreshAll()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Looks for BeamNG.drive in the usual places (Steam libraries, Games folders, external drives).
    static func findGameDir() -> String? {
        let fm = FileManager.default
        let h = Paths.home.path
        var candidates = [
            "\(h)/Games/BeamNG.drive", "\(h)/Applications/BeamNG.drive", "/Applications/BeamNG.drive",
            "\(h)/Library/Application Support/Steam/steamapps/common/BeamNG.drive",
            "\(h)/SteamLibrary/steamapps/common/BeamNG.drive",
        ]
        for base in ["\(h)/Desktop", "\(h)/Documents", "\(h)/Downloads"] + ((try? fm.contentsOfDirectory(atPath: "/Volumes"))?.map { "/Volumes/\($0)" } ?? []) {
            candidates.append("\(base)/SteamLibrary/steamapps/common/BeamNG.drive")
            candidates.append("\(base)/BeamNG.drive")
            for sub in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
                candidates.append("\(base)/\(sub)/SteamLibrary/steamapps/common/BeamNG.drive")
                candidates.append("\(base)/\(sub)/BeamNG.drive")
            }
        }
        return candidates.first { fm.fileExists(atPath: $0 + "/BeamNG.drive.exe") }
    }

    /// Copies the helper scripts bundled in the app into the launcher folder.
    func installScripts() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("scripts") else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.bin, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
            let dst = Paths.bin.appendingPathComponent(f)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src.appendingPathComponent(f), to: dst)
            chmod(dst.path, 0o755)
        }
    }

    func refreshAll() {
        refreshSetup()
        loadGraphics()
        refreshDevices()
        refreshFogFix()
    }

    func refreshSetup() {
        let fm = FileManager.default
        let installs = (try? fm.contentsOfDirectory(atPath: Paths.wineInstalls.path)) ?? []
        wineOK = installs.contains { fm.isExecutableFile(atPath: Paths.wineInstalls.appendingPathComponent($0).appendingPathComponent("bin/wine").path) }
        prefixOK = fm.fileExists(atPath: Paths.prefix.appendingPathComponent("system.reg").path)
        gptkVersions = ((try? fm.contentsOfDirectory(atPath: Paths.gptk.path)) ?? [])
            .filter { $0 != "current" && fm.fileExists(atPath: Paths.gptk.appendingPathComponent($0 + "/external/libd3dshared.dylib").path) }
            .sorted().reversed()
        currentGPTK = (try? fm.destinationOfSymbolicLink(atPath: Paths.gptk.appendingPathComponent("current").path)) ?? ""
        if !gptkVersions.contains(currentGPTK) { currentGPTK = gptkVersions.first ?? "" }
    }

    func tick() {
        let running = processRunning("BeamNG.drive.x64.exe")
        let starting = !running && (processRunning("BeamNG-GPTK4/bin/launch.sh") || processRunning("BeamNG.drive.exe"))
        state = running ? .running : (starting ? .starting : .stopped)
        if lastState != .stopped && state == .stopped {
            // game just closed: it rewrote settings.json, so apply anything queued and reload
            if !pendingChanges.isEmpty { GameSettingsFile.merge(pendingChanges); pendingChanges = [:]; message = "Saved your queued graphics changes." }
            loadGraphics(); refreshFogFix()
        }
        lastState = state
        if Int(Date().timeIntervalSince1970) % 4 == 0 { refreshDevices() }
    }

    func refreshDevices() {
        devices = ControllerScanner.scan()
        seenByGame = ControllerScanner.seenByGame()
    }

    // MARK: graphics

    func loadGraphics() {
        let d = gameDefaults(gameDir: conf.gameDir)
        let s = GameSettingsFile.load()
        func v(_ k: String) -> Any? { s[k] ?? d[k] }
        preset = "\(v("GraphicOverallQuality") ?? "Normal")"
        renderScale = (v("GraphicUpscalingQuality") as? NSNumber)?.doubleValue ?? 1
        aaType = (s["GraphicAntialias"] as? NSNumber)?.intValue == 0 ? "off" : "\(v("GraphicAntialiasType") ?? "fxaa")"
        sharpness = (v("GraphicUpscalingSharpness") as? NSNumber)?.doubleValue ?? 0.25
        shadows = "\(v("GraphicShadowsQuality") ?? "Normal")"
        meshes = "\(v("GraphicMeshQuality") ?? "Normal")"
        windowRes = "\(v("GraphicDisplayResolutions") ?? "1280 720")"
    }

    /// Writes now if the game is closed, otherwise queues until it exits.
    func change(_ values: [String: Any]) {
        if state == .stopped {
            GameSettingsFile.merge(values)
            message = "Saved. Takes effect next time the game starts."
        } else {
            for (k, v) in values { pendingChanges[k] = v }
            message = "The game is running — changes apply when it restarts."
        }
    }

    func applyPreset(_ name: String) {
        guard var p = gamePresets(gameDir: conf.gameDir)[name] else { return }
        p["GraphicOverallQuality"] = name
        preset = name
        if let s = p["GraphicShadowsQuality"] { shadows = "\(s)" }
        if let m = p["GraphicMeshQuality"] { meshes = "\(m)" }
        change(p)
    }

    func setDetail(_ key: String, _ value: String) {
        var changes: [String: Any] = [key: value]
        // label as Custom unless it still matches the chosen preset
        if let p = gamePresets(gameDir: conf.gameDir)[preset], "\(p[key] ?? "")" != value {
            preset = "Custom"; changes["GraphicOverallQuality"] = "Custom"
        }
        change(changes)
    }

    func setAA(_ type: String) {
        aaType = type
        change(type == "off" ? ["GraphicAntialiasType": "off", "GraphicAntialias": 0]
                             : ["GraphicAntialiasType": type, "GraphicAntialias": 4])
    }

    func setWindow(_ res: String) {
        windowRes = res
        change(["GraphicDisplayResolutions": res, "GraphicDisplayModes": "Window"])
    }

    var windowChoices: [(String, String)] {
        var list = [("1280 720", "1280 × 720"), ("1600 900", "1600 × 900"), ("1920 1080", "1920 × 1080")]
        if let f = NSScreen.main?.visibleFrame {
            let w = Int(f.width), h = Int(f.height) - 28
            list.insert(("\(w) \(h)", "Fit screen (\(w) × \(h))"), at: 0)
        }
        if !list.contains(where: { $0.0 == windowRes }) {
            list.append((windowRes, windowRes.replacingOccurrences(of: " ", with: " × ")))
        }
        return list
    }

    // MARK: fog fix mod

    var fogModDir: URL { Paths.mods.appendingPathComponent("unpacked/noFogFix") }

    func refreshFogFix() {
        guard FileManager.default.fileExists(atPath: fogModDir.path) else { fogFix = false; return }
        let db = Paths.mods.appendingPathComponent("db.json")
        if let d = try? Data(contentsOf: db), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let mods = o["mods"] as? [String: Any], let e = mods["nofogfix"] as? [String: Any] {
            fogFix = (e["active"] as? Bool) ?? true
        } else { fogFix = true }
    }

    func setFogFix(_ on: Bool) {
        guard state == .stopped else { message = "Quit the game first to change mods."; refreshFogFix(); return }
        let fm = FileManager.default
        let db = Paths.mods.appendingPathComponent("db.json")
        var obj = (try? Data(contentsOf: db)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var mods = obj["mods"] as? [String: Any] ?? [:]
        if on {
            if !fm.fileExists(atPath: fogModDir.path), let src = Bundle.main.resourceURL?.appendingPathComponent("noFogFix") {
                try? fm.createDirectory(at: fogModDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: src, to: fogModDir)
            }
            if var e = mods["nofogfix"] as? [String: Any] { e["active"] = true; mods["nofogfix"] = e }
        } else {
            if var e = mods["nofogfix"] as? [String: Any] { e["active"] = false; mods["nofogfix"] = e }
            else { try? fm.removeItem(at: fogModDir) }
        }
        if !mods.isEmpty {
            obj["mods"] = mods
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) { try? d.write(to: db) }
        }
        fogFix = on
        message = on ? "Fog fix turned on." : "Fog fix turned off."
    }

    // MARK: game control

    func play() {
        guard setupComplete else { message = "Finish setup first."; return }
        conf.save()
        if !pendingChanges.isEmpty { GameSettingsFile.merge(pendingChanges); pendingChanges = [:] }
        runShell(Paths.bin.appendingPathComponent("launch.sh"), wait: false)
        state = .starting; lastState = .starting
        message = "Starting BeamNG…"
    }

    func quitGame(then: (@MainActor () -> Void)? = nil) {
        busy = true; message = "Closing BeamNG…"
        Task.detached {
            runShell(Paths.bin.appendingPathComponent("quit.sh"))
            await MainActor.run {
                self.busy = false
                self.tick()
                self.message = self.state == .stopped ? "BeamNG closed." : "BeamNG is still closing…"
                then?()
            }
        }
    }

    func restart() { quitGame { self.play() } }

    func clearShaderCache() {
        guard state == .stopped else { message = "Quit the game first."; return }
        let fm = FileManager.default
        var removed = 0
        for url in [Paths.userRoot.appendingPathComponent("temp/shaders"),
                    Paths.userCache.appendingPathComponent("d3dm/BeamNG.drive.x64.exe")] where fm.fileExists(atPath: url.path) {
            if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { removed += 1 }
        }
        message = removed > 0 ? "Shader caches moved to the Trash. The next start will be slower while they rebuild."
                              : "No shader cache to clear."
    }

    func resetDefaults() {
        guard state == .stopped else { message = "Quit the game first."; return }
        GameSettingsFile.backup(tag: "launcher-reset")
        var p = gamePresets(gameDir: conf.gameDir)["High"] ?? [:]
        p["GraphicOverallQuality"] = "High"
        p["GraphicAntialiasType"] = "fsr3"; p["GraphicAntialias"] = 4
        p["GraphicUpscalingQuality"] = 1.0; p["GraphicUpscalingSharpness"] = 0.3
        p["GraphicDisplayModes"] = "Window"
        if let f = NSScreen.main?.visibleFrame { p["GraphicDisplayResolutions"] = "\(Int(f.width)) \(Int(f.height) - 28)" }
        GameSettingsFile.merge(p)
        conf.fixTrees = true; conf.metal4 = true; conf.fpsHUD = false; conf.extraArgs = ""
        conf.gptkVersion = "current"; conf.save()
        if fogFix { setFogFix(false) }
        loadGraphics()
        message = "Back to recommended settings (High, native resolution, FSR 3, windowed). Old settings were backed up."
    }

    // MARK: setup actions

    func chooseGameDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the BeamNG.drive folder (the one that contains BeamNG.drive.exe)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("BeamNG.drive.exe").path) {
            conf.gameDir = url.path; conf.save(); loadGraphics()
            message = "Game folder set."
        } else {
            message = "That folder doesn't contain BeamNG.drive.exe."
        }
    }

    func installGPTK() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage]
        panel.message = "Choose Apple's \"Evaluation environment for Windows games\" .dmg"
        panel.directoryURL = Paths.home.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; message = "Installing GPTK…"
        Task.detached {
            let (code, out) = runShell(Paths.bin.appendingPathComponent("install-gptk.sh"), [url.path])
            await MainActor.run {
                self.busy = false
                self.message = code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : "GPTK install failed: \(out)"
                self.conf.gptkVersion = "current"; self.conf.save()
                self.refreshSetup()
            }
        }
    }

    func selectGPTK(_ v: String) {
        try? FileManager.default.removeItem(at: Paths.gptk.appendingPathComponent("current"))
        try? FileManager.default.createSymbolicLink(atPath: Paths.gptk.appendingPathComponent("current").path, withDestinationPath: v)
        conf.gptkVersion = "current"; conf.save()
        refreshSetup()
        message = "Using GPTK \(v)" + (state == .stopped ? "." : " from the next start.")
    }

    func importRuntime() {
        guard state == .stopped else { message = "Quit the game first."; return }
        busy = true; message = "Importing Wine from GameHub… (this takes a few seconds)"
        Task.detached {
            let (code, out) = runShell(Paths.bin.appendingPathComponent("setup-runtime.sh"))
            await MainActor.run {
                self.busy = false
                self.message = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if code == 0 { self.refreshAll() }
            }
        }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

// MARK: - UI

struct StatusDot: View {
    let state: Launcher.GameState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
    var color: Color { state == .running ? .green : (state == .starting ? .orange : .gray) }
    var label: String { state == .running ? "Running" : (state == .starting ? "Starting…" : "Not running") }
}

struct CheckRow: View {
    let ok: Bool; let title: String; let detail: String
    var optional = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : (optional ? "minus.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(ok ? .green : (optional ? .gray : .red))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle) }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Launcher
    @AppStorage("showAdvanced") var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !m.setupComplete { setupBox }
                    graphicsBox
                    controllersBox
                    Toggle("Enable advanced settings", isOn: $showAdvanced.animation(.easeInOut(duration: 0.2)))
                        .toggleStyle(.switch).controlSize(.small)
                        .padding(.horizontal, 4)
                    if showAdvanced {
                        fixesBox
                        toolsBox
                    }
                }
                .padding(16)
            }
            if !m.message.isEmpty {
                Divider()
                HStack {
                    if m.busy { ProgressView().controlSize(.small) }
                    Text(m.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .frame(width: 460)
        .frame(minHeight: 400, idealHeight: 520, maxHeight: .infinity)
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("BeamNG.drive").font(.title2.bold())
                HStack(spacing: 10) {
                    StatusDot(state: m.state)
                    Text("GPTK \(m.currentGPTK.isEmpty ? "—" : m.currentGPTK)\(m.conf.metal4 ? " · Metal 4" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if m.state == .stopped {
                Button { m.play() } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 70) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!m.setupComplete || m.busy)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button { m.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    .controlSize(.large).disabled(m.busy)
                Button(role: .destructive) { m.quitGame() } label: { Label("Quit", systemImage: "stop.fill") }
                    .controlSize(.large).disabled(m.busy)
            }
        }
        .padding(16)
    }

    var setupBox: some View {
        GroupBox("Setup") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CheckRow(ok: m.wineOK && m.prefixOK, title: "Wine runtime",
                             detail: m.wineOK && m.prefixOK ? "Installed" : "Imported from GameHub (install it and run any game once)")
                    Spacer()
                    Button("Import from GameHub") { m.importRuntime() }.disabled(m.busy)
                }
                HStack {
                    CheckRow(ok: m.gptkOK, title: "Apple Game Porting Toolkit",
                             detail: m.gptkOK ? m.currentGPTK : "Download \"Evaluation environment for Windows games\" from Apple")
                    Spacer()
                    Button("Get from Apple") { m.open(URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!) }
                    Button("Install .dmg…") { m.installGPTK() }.disabled(m.busy)
                }
                HStack {
                    CheckRow(ok: m.gameDirOK, title: "BeamNG.drive folder", detail: m.gameDirOK ? m.conf.gameDir : "Not chosen")
                    Spacer()
                    Button("Choose…") { m.chooseGameDir() }
                }
            }
            .padding(6)
        }
    }

    var graphicsBox: some View {
        GroupBox("Graphics") {
            VStack(alignment: .leading, spacing: 10) {
                if !m.pendingChanges.isEmpty {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                        Text("Changes wait until the game restarts.").font(.callout)
                        Spacer()
                        Button("Apply & Restart") { m.restart() }.disabled(m.busy)
                    }
                }
                LabeledContent("Preset") {
                    Picker("", selection: Binding(get: { m.preset }, set: { m.applyPreset($0) })) {
                        ForEach(m.presetNames, id: \.self) { Text($0).tag($0) }
                        if !m.presetNames.contains(m.preset) { Text(m.preset).tag(m.preset) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                if showAdvanced { advancedGraphics }
                LabeledContent("Window size") {
                    Picker("", selection: Binding(get: { m.windowRes }, set: { m.setWindow($0) })) {
                        ForEach(m.windowChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }.labelsHidden().frame(width: 220)
                }
                Toggle("Show FPS counter", isOn: Binding(get: { m.conf.fpsHUD }, set: { m.conf.fpsHUD = $0; m.conf.save(); m.message = "FPS counter \($0 ? "on" : "off") from the next start." }))
            }
            .padding(6)
        }
    }

    @ViewBuilder var advancedGraphics: some View {
                LabeledContent("Anti-aliasing") {
                    Picker("", selection: Binding(get: { m.aaType }, set: { m.setAA($0) })) {
                        Text("Off").tag("off"); Text("FXAA").tag("fxaa"); Text("SMAA").tag("smaa")
                        Text("SMAA T2x").tag("smaaT2x"); Text("FSR 3 (best)").tag("fsr3")
                        if !["off", "fxaa", "smaa", "smaaT2x", "fsr3"].contains(m.aaType) { Text(m.aaType).tag(m.aaType) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                LabeledContent("Render scale") {
                    HStack {
                        Slider(value: $m.renderScale, in: 0.5...1.0, step: 0.05) { editing in
                            if !editing { m.change(["GraphicUpscalingQuality": (m.renderScale * 100).rounded() / 100]) }
                        }
                        Text("\(Int((m.renderScale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(m.aaType != "fsr3")
                LabeledContent("Sharpness") {
                    HStack {
                        Slider(value: $m.sharpness, in: 0...1, step: 0.05) { editing in
                            if !editing { m.change(["GraphicUpscalingSharpness": (m.sharpness * 100).rounded() / 100]) }
                        }
                        Text("\(Int((m.sharpness * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(m.aaType != "fsr3")
                if m.aaType != "fsr3" {
                    Text("Render scale and sharpness work with FSR 3.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    LabeledContent("Shadows") {
                        Picker("", selection: Binding(get: { m.shadows }, set: { m.shadows = $0; m.setDetail("GraphicShadowsQuality", $0) })) {
                            ForEach(["Disabled", "Lowest", "Low", "Normal", "High", "Ultra"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                    LabeledContent("Meshes") {
                        Picker("", selection: Binding(get: { m.meshes }, set: { m.meshes = $0; m.setDetail("GraphicMeshQuality", $0) })) {
                            ForEach(["Lowest", "Low", "Normal", "High", "Ultra"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 100)
                    }
                }
    }

    var controllersBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                let pads = m.devices.filter { $0.kind != .wheel }
                let wheels = m.devices.filter { $0.kind == .wheel }
                CheckRow(ok: !pads.isEmpty, title: pads.isEmpty ? "No controller connected" : "Controller detected",
                         detail: pads.map { "\($0.name) · \($0.connection)" }.joined(separator: "\n"), optional: true)
                CheckRow(ok: !wheels.isEmpty, title: wheels.isEmpty ? "No steering wheel connected" : "Steering wheel detected",
                         detail: wheels.map { "\($0.name) · \($0.connection)" }.joined(separator: "\n"), optional: true)
                if !m.seenByGame.isEmpty {
                    Text("BeamNG saw last time: " + m.seenByGame.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack { Text("Controllers"); Spacer(); Button { m.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Scan again") }
        }
    }

    var fixesBox: some View {
        GroupBox("Compatibility") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { m.conf.fixTrees }, set: { m.conf.fixTrees = $0; m.conf.save() })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Fix missing trees and objects")
                        Text("-nogfxgpudriven · needed until Apple fixes GPU-driven drawing; costs some FPS").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { m.conf.metal4 }, set: { m.conf.metal4 = $0; m.conf.save() })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Metal 4")
                        Text("Needed for shadows").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { m.fogFix }, set: { m.setFogFix($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Disable fog (noFogFix mod)")
                        Text("Only needed on GPTK 3 — GPTK 4 draws fog correctly").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("GPTK version")
                    Picker("", selection: Binding(get: { m.currentGPTK }, set: { m.selectGPTK($0) })) {
                        ForEach(m.gptkVersions, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 110).disabled(m.gptkVersions.isEmpty)
                    Spacer()
                    Button("Install .dmg…") { m.installGPTK() }.disabled(m.busy)
                }
                LabeledContent("Extra launch options") {
                    TextField("e.g. -console", text: Binding(get: { m.conf.extraArgs }, set: { m.conf.extraArgs = $0; m.conf.save() }))
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
            .padding(6)
        }
    }

    var toolsBox: some View {
        GroupBox("Tools") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Clear shader cache") { m.clearShaderCache() }
                    Button("Reset to defaults") { confirmReset() }
                }
                HStack {
                    Button("Game folder…") { m.chooseGameDir() }
                    Button("Open mods folder") { m.open(Paths.mods) }
                    Button("Open game log") { m.open(Paths.gameLog) }
                }
                Text(m.conf.gameDir.isEmpty ? "No game folder chosen" : m.conf.gameDir)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func confirmReset() {
        let a = NSAlert()
        a.messageText = "Reset to recommended settings?"
        a.informativeText = "High preset, full resolution with FSR 3, windowed, tree fix and Metal 4 on, fog fix off. Your current game settings are backed up first."
        a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { m.resetDefaults() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
}

@main
struct BeamNGLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Launcher()
    var body: some Scene {
        WindowGroup("BeamNG Launcher") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 460, height: 520)
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
