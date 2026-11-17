// BeamNG Launcher — runs BeamNG.drive on macOS through Wine + Apple D3DMetal (GPTK).
// Build: see build.sh next to this file.
import SwiftUI
import AppKit
import IOKit
import IOKit.hid
import GameController
import CryptoKit

/// Looks a launcher string up in the bundle's Localizable.strings (English text is the key).
func L(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }

struct LauncherError: LocalizedError {
    let text: String
    init(_ t: String) { text = t }
    var errorDescription: String? { text }
}

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
    static let logs = root.appendingPathComponent("logs")
    static let addons = root.appendingPathComponent("addons")
    static let addonVersions = addons.appendingPathComponent("versions.json")
    static let beammpExe = addons.appendingPathComponent("beammp/BeamMP-Launcher.exe")
    static let earthExe = addons.appendingPathComponent("beamng-earth/BeamNG.Earth.exe")
    static let dxvk = addons.appendingPathComponent("dxvk")
    static let dxvkDll = dxvk.appendingPathComponent("x86_64-windows/d3d11.dll")
    static let earthMod = mods.appendingPathComponent("unpacked/beamng_earth")
    static let ffbMod = mods.appendingPathComponent("unpacked/pedalboxFFB")
    static let earthngPlanet = mods.appendingPathComponent("earthng_planet.zip")
    static let beamngIni = prefix.appendingPathComponent("drive_c/users/steamuser/AppData/Local/BeamNG/BeamNG.drive.ini")
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
    var beammp = false
    var earth = false
    var discord = true
    var renderer = "d3d12"   // d3d12, d3d11, vulkan, dxvk
    var span = false         // stretch the game window across all displays
    var hidraw = ""          // wheels Wine should pass through as raw HID, "0x046D/0xC24F,…" (set at each start)
    var ffb = false          // wheel force feedback through PedalBox

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
            case "BEAMMP": c.beammp = val == "1"
            case "EARTH": c.earth = val == "1"
            case "DISCORD": c.discord = val != "0"
            case "SPAN": c.span = val == "1"
            case "HIDRAW": c.hidraw = val
            case "FFB": c.ffb = val == "1"
            case "RENDERER": c.renderer = ["d3d12", "d3d11", "vulkan", "dxvk"].contains(val) ? val : "d3d12"
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
        BEAMMP=\(beammp ? 1 : 0)
        EARTH=\(earth ? 1 : 0)
        DISCORD=\(discord ? 1 : 0)
        RENDERER=\(renderer)
        SPAN=\(span ? 1 : 0)
        HIDRAW=\(q(hidraw))
        FFB=\(ffb ? 1 : 0)

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

// MARK: - Languages

enum Languages {
    /// Native names of BeamNG's official languages (folder names in the game's locales/translations).
    static let names: [String: String] = [
        "en-US": "English", "de_DE": "Deutsch", "es_ES": "Español (España)", "es_419": "Español (Latinoamérica)",
        "fr_FR": "Français", "ja_JP": "日本語", "ko_KR": "한국어", "pl_PL": "Polski",
        "pt_BR": "Português (Brasil)", "pt_PT": "Português (Portugal)", "ru_RU": "Русский",
        "zh_Hans": "简体中文", "zh_Hant": "繁體中文",
    ]
    /// The launcher's own translations (.lproj) for each game language.
    static let launcherCode: [String: String] = [
        "en-US": "en", "de_DE": "de", "es_ES": "es", "es_419": "es-419", "fr_FR": "fr", "ja_JP": "ja", "ko_KR": "ko",
        "pl_PL": "pl", "pt_BR": "pt-BR", "pt_PT": "pt-PT", "ru_RU": "ru", "zh_Hans": "zh-Hans", "zh_Hant": "zh-Hant",
    ]

    /// Every language the installed game ships (falls back to the known list).
    static func game(gameDir: String) -> [String] {
        let dir = URL(fileURLWithPath: gameDir).appendingPathComponent("locales/translations")
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        let list = found.isEmpty ? Array(names.keys) : found
        return list.sorted { name($0).localizedCompare(name($1)) == .orderedAscending }
    }
    static func name(_ key: String) -> String { names[key] ?? key }

    static var launcherOverride: String {
        (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first.flatMap { code in
            UserDefaults.standard.bool(forKey: "launcherLanguageSet") ? code : nil
        } ?? ""
    }
}

// MARK: - Discord Rich Presence

/// Talks to the Discord app over its local IPC socket ($TMPDIR/discord-ipc-N). The game's own Discord
/// support can't reach it from inside Wine, so the launcher relays what the game reports in its log.
final class DiscordPresence {
    /// Discord's application for BeamNG.drive (its public "detectable games" entry), so friends see
    /// "Playing BeamNG.drive" with the game's icon.
    static let clientID = "363413743335374859"

    private let queue = DispatchQueue(label: "discord-ipc")
    private var fd: Int32 = -1
    private var lastPayload = ""

    static var discordRunning: Bool {
        (0..<10).contains { FileManager.default.fileExists(atPath: socketPath($0)) }
    }
    private static func socketPath(_ n: Int) -> String {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        return (tmp as NSString).appendingPathComponent("discord-ipc-\(n)")
    }

    /// details/state: the two text lines; start: when the game started. nil clears the status.
    func update(details: String?, state: String?, start: Date?) {
        queue.async { [self] in
            guard let details else { clearLocked(); return }
            var activity: [String: Any] = ["details": String(details.prefix(127))]
            if let state, !state.isEmpty { activity["state"] = String(state.prefix(127)) }
            if let start { activity["timestamps"] = ["start": Int(start.timeIntervalSince1970)] }
            let args: [String: Any] = ["pid": Int(getpid()), "activity": activity]
            let key = "\(details)|\(state ?? "")|\(start?.timeIntervalSince1970 ?? 0)"
            guard key != lastPayload || fd < 0 else { return }
            if fd < 0 && !connectLocked() { return }
            if send(op: 1, ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString]) {
                lastPayload = key
            } else {
                closeLocked()
            }
        }
    }

    func clear() { queue.async { [self] in clearLocked() } }

    private func clearLocked() {
        if fd >= 0 {
            _ = send(op: 1, ["cmd": "SET_ACTIVITY", "args": ["pid": Int(getpid())], "nonce": UUID().uuidString])
        }
        closeLocked()
    }

    private func connectLocked() -> Bool {
        for n in 0..<10 {
            let path = Self.socketPath(n)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let bytes = Array(path.utf8.prefix(buf.count - 1))
                buf.copyBytes(from: bytes)
                buf[bytes.count] = 0
            }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard ok else { Darwin.close(s); continue }
            fd = s
            if send(op: 0, ["v": 1, "client_id": Self.clientID]) { return true }
            closeLocked()
        }
        return false
    }

    /// Writes one frame (op, length, JSON) and reads Discord's reply.
    private func send(op: UInt32, _ payload: [String: Any]) -> Bool {
        guard fd >= 0, let json = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var frame = Data()
        withUnsafeBytes(of: op.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(json)
        let wrote = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, frame.count) }
        guard wrote == frame.count else { return false }
        var header = [UInt8](repeating: 0, count: 8)
        guard Darwin.read(fd, &header, 8) == 8 else { return false }
        let replyOp = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        let len = Int(UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24)
        var body = [UInt8](repeating: 0, count: max(len, 0))
        var got = 0
        while got < len {
            let n = body.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, len - got) }
            if n <= 0 { return false }
            got += n
        }
        return replyOp != 2   // 2 = Discord closed the connection (e.g. bad client id)
    }

    private func closeLocked() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        lastPayload = ""
    }
}

/// The game's latest Rich Presence text ("Playing Freeroam on West Coast Usa with Hirochi Accent"),
/// read from the end of beamng.log when the log was written since `since`.
func latestRichPresence(since: Date) -> String? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.gameLog.path),
          let mod = attrs[.modificationDate] as? Date, mod >= since.addingTimeInterval(-5),
          let h = try? FileHandle(forReadingFrom: Paths.gameLog) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
    guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
    // The log has Windows line endings ("\r\n" is one Character in Swift, so split on isNewline).
    // Only the debug lines util_richPresence writes with the status text count; its info lines
    // ("Setting activity to …") and the startup line ("Rich Presence is enabled…") don't.
    let marker = "|D|GELua.util_richPresence.Rich Presence| "
    for line in text.split(whereSeparator: \.isNewline).reversed() {
        guard let r = line.range(of: marker) else { continue }
        let msg = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        if msg.isEmpty || msg.hasPrefix("Rich Presence") || msg.contains("|") { continue }
        return msg == "Playing" ? nil : msg     // plain "Playing" is the main menu
    }
    return nil
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
        if looksLikeCode { base = L("Game controller") }
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
        for line in text.split(whereSeparator: \.isNewline) where line.contains("Device connected:") {
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
    @Published var displayMode = "Window"
    @Published var screensTick = 0      // bumps when displays are added, removed or rearranged
    @Published var pendingChanges: [String: Any] = [:]
    @Published var fogFix = false
    @Published var gameLanguage = ""

    // add-ons: BeamMP, BeamNG.Earth, EarthNG
    @Published var beammpInstalled = false
    @Published var earthInstalled = false
    @Published var dxvkInstalled = false
    @Published var earthngInstalled = false
    @Published var earthngPacks: [String] = []
    @Published var addonVersions: [String: String] = [:]
    @Published var updates: Set<String> = []
    @Published var beammpRunning = false
    @Published var earthRunning = false
    @Published var downloadTitle = ""
    @Published var downloadFraction = 0.0
    @Published var downloading = false
    private var downloadTask: URLSessionDownloadTask?

    // Discord Rich Presence
    @Published var discordRunning = false
    private let discord = DiscordPresence()
    private var gameStartedAt: Date?
    private var progressTimer: Timer?

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

    /// Below the game's own Lowest: half-resolution rendering (FSR 3), a 30 FPS cap, every effect off and
    /// no parked cars (each one is a full physics vehicle). For 8 GB / base-chip Macs.
    static let potatoExtras: [String: Any] = [
        "GraphicAntialiasType": "fsr3", "GraphicAntialias": 4,
        "GraphicUpscalingQuality": 0.5, "GraphicUpscalingSharpness": 0.5,
        "GraphicMaxDecalCount": 500, "GraphicGrassDensity": 0, "GraphicAnisotropic": 0,
        "GraphicDynReflectionQuality": "Disabled", "GraphicDynMirrorsQuality": "Disabled",
        "GraphicCloudsQuality": "Disabled",
        "PostFXSSAOGeneralEnabled": false, "PostFXMotionBlurEnabled": false, "PostFXDOFGeneralEnabled": false,
        "PostFXScreenSpaceShadowsEnabled": false, "PostFXSSREnabled": false,
        "fpsLimitEnabled": true, "fpsLimit": 30, "fpsLimitBackgroundEnabled": true, "fpsLimitBackground": 10,
        "trafficParkedVehicles": false, "trafficParkingAmount": 0,
        "SkipGenerateLicencePlate": true, "vehicleShadowEnabled": false,
    ]
    /// What Potato changed that the game's own presets don't set back.
    static let potatoUndo: [String: Any] = [
        "GraphicUpscalingQuality": 1.0, "GraphicUpscalingSharpness": 0.3,
        "PostFXSSAOGeneralEnabled": true, "PostFXMotionBlurEnabled": true,
        "fpsLimitEnabled": false, "fpsLimitBackground": 30,
        "trafficParkedVehicles": true, "trafficParkingAmount": 5, "vehicleShadowEnabled": true,
    ]
    static func isPotato(_ s: [String: Any]) -> Bool {
        "\(s["GraphicOverallQuality"] ?? "")" == "Custom"
            && (s["GraphicUpscalingQuality"] as? NSNumber)?.doubleValue == 0.5
            && (s["fpsLimitEnabled"] as? Bool) == true && (s["trafficParkedVehicles"] as? Bool) == false
    }

    init() {
        installScripts()
        if conf.gameDir.isEmpty, let found = Launcher.findGameDir() { conf.gameDir = found; conf.save() }
        refreshAll()
        tick()
        Task { await checkAddonUpdates() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensTick += 1 }
        }
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
        refreshAddons()
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
            if !pendingChanges.isEmpty { GameSettingsFile.merge(pendingChanges); pendingChanges = [:]; message = L("Saved your queued changes.") }
            loadGraphics(); refreshFogFix(); refreshAddons()
        }
        lastState = state
        updateDiscord()
        beammpRunning = state != .stopped && processRunning("BeamMP-Launcher.exe")
        earthRunning = state != .stopped && processRunning("BeamNG.Earth.exe")
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
        preset = Launcher.isPotato(s) ? "Potato" : "\(v("GraphicOverallQuality") ?? "Normal")"
        renderScale = (v("GraphicUpscalingQuality") as? NSNumber)?.doubleValue ?? 1
        aaType = (s["GraphicAntialias"] as? NSNumber)?.intValue == 0 ? "off" : "\(v("GraphicAntialiasType") ?? "fxaa")"
        sharpness = (v("GraphicUpscalingSharpness") as? NSNumber)?.doubleValue ?? 0.25
        shadows = "\(v("GraphicShadowsQuality") ?? "Normal")"
        meshes = "\(v("GraphicMeshQuality") ?? "Normal")"
        windowRes = "\(v("GraphicDisplayResolutions") ?? "1280 720")"
        displayMode = conf.span ? "Span" : "\(v("GraphicDisplayModes") ?? "Window")"
        gameLanguage = s["userLanguage"] as? String ?? ""
    }

    /// Writes now if the game is closed, otherwise queues until it exits.
    func change(_ values: [String: Any]) {
        if state == .stopped {
            GameSettingsFile.merge(values)
            message = L("Saved. Takes effect next time the game starts.")
        } else {
            for (k, v) in values { pendingChanges[k] = v }
            message = L("The game is running — changes apply when it restarts.")
        }
    }

    func applyPreset(_ name: String) {
        if name == "Potato" {
            var p = gamePresets(gameDir: conf.gameDir)["Lowest"] ?? [:]
            for (k, v) in Launcher.potatoExtras { p[k] = v }
            p["GraphicOverallQuality"] = "Custom"
            if state == .stopped, preset != "Potato" { GameSettingsFile.backup(tag: "before-potato") }
            preset = "Potato"; shadows = "\(p["GraphicShadowsQuality"] ?? "Lowest")"; meshes = "\(p["GraphicMeshQuality"] ?? "Lowest")"
            aaType = "fsr3"; renderScale = 0.5; sharpness = 0.5
            change(p)
            return
        }
        guard var p = gamePresets(gameDir: conf.gameDir)[name] else { return }
        if preset == "Potato" {
            for (k, v) in Launcher.potatoUndo where p[k] == nil { p[k] = v }
            renderScale = 1.0; sharpness = 0.3
        }
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

    /// The main screen's size in pixels (what full screen modes render at).
    var screenPixels: (Int, Int) {
        guard let sc = NSScreen.main else { return (1920, 1080) }
        return (Int(sc.frame.width * sc.backingScaleFactor), Int(sc.frame.height * sc.backingScaleFactor))
    }

    func setDisplayMode(_ mode: String) {
        if mode == "Span" {
            conf.span = true; conf.save(); displayMode = "Span"
            message = L("The game window will cover all displays from the next start.")
            return
        }
        if conf.span { conf.span = false; conf.save() }
        if mode == "Window" {
            var res = windowRes
            if displayMode != "Window", let f = NSScreen.main?.visibleFrame { res = "\(Int(f.width)) \(Int(f.height) - 28)" }
            displayMode = mode; windowRes = res
            change(["GraphicDisplayModes": "Window", "GraphicDisplayResolutions": res])
        } else {
            let (w, h) = screenPixels
            displayMode = mode; windowRes = "\(w) \(h)"
            change(["GraphicDisplayModes": mode, "GraphicDisplayResolutions": "\(w) \(h)"])
        }
    }

    /// Render scale needs FSR 3 (it renders smaller and scales up), so turn it on if needed.
    func setRenderScale(_ value: Double) {
        let v = (value * 100).rounded() / 100
        renderScale = v
        var c: [String: Any] = ["GraphicUpscalingQuality": v]
        if aaType != "fsr3" { aaType = "fsr3"; c["GraphicAntialiasType"] = "fsr3"; c["GraphicAntialias"] = 4 }
        change(c)
    }

    /// e.g. "840 × 525" for 50 % of a 1680 × 1050 screen.
    var renderResolution: String {
        let parts = windowRes.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else { return "" }
        let s = aaType == "fsr3" ? renderScale : 1
        return "\(Int((parts[0] * s).rounded())) × \(Int((parts[1] * s).rounded()))"
    }

    // MARK: span all displays

    struct SpanArea { let x, y, w, h: Int }

    /// The largest rectangle one window can cover across all displays, in Windows coordinates (Wine's Mac
    /// driver: points, top-left of the menu-bar display is 0,0, y grows down). Side-by-side displays give
    /// their full width at the height they share; stacked ones the reverse. A single display gives its own visible area.
    static func spanArea() -> SpanArea? {
        let screens = NSScreen.screens
        guard let main = screens.first else { return nil }
        if screens.count == 1 {      // one display: fill it, like "Fit screen"
            let v = main.visibleFrame
            return SpanArea(x: Int(v.minX), y: Int(main.frame.maxY - v.maxY), w: Int(v.width), h: Int(v.height))
        }
        let top = main.frame.maxY
        let r = screens.map { s -> CGRect in
            let v = s.visibleFrame
            return CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)
        }
        let minX = r.map(\.minX).min()!, maxX = r.map(\.maxX).max()!
        let minY = r.map(\.minY).min()!, maxY = r.map(\.maxY).max()!
        var a = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        // the arrangement comes from the whole screens (visible areas have menu bar and Dock gaps)
        let f = screens.map(\.frame)
        let fw = f.map(\.maxX).max()! - f.map(\.minX).min()!, fh = f.map(\.maxY).max()! - f.map(\.minY).min()!
        if abs(f.map(\.width).reduce(0, +) - fw) < 8 {                 // side by side
            let t = r.map(\.minY).max()!, b = r.map(\.maxY).min()!
            if b - t > 200 { a = CGRect(x: minX, y: t, width: maxX - minX, height: b - t) }
        } else if abs(f.map(\.height).reduce(0, +) - fh) < 8 {         // stacked
            let l = r.map(\.minX).max()!, rt = r.map(\.maxX).min()!
            if rt - l > 200 { a = CGRect(x: l, y: minY, width: rt - l, height: maxY - minY) }
        }
        return SpanArea(x: Int(a.minX), y: Int(a.minY), w: Int(a.width), h: Int(a.height))
    }

    /// macOS only lets a window cover several displays when "Displays have separate Spaces" is off.
    static var displaysShareSpace: Bool {
        UserDefaults(suiteName: "com.apple.spaces")?.bool(forKey: "spans-displays") ?? false
    }

    static func openSpacesSetting() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    /// Before each start: a window the size of all displays, placed at their top-left. BeamNG restores
    /// WindowPlacement ("flags show minX minY maxX maxY left top bottom right", relative to the main
    /// display's work area) when it opens in window mode.
    func applySpan() {
        guard conf.span, let a = Launcher.spanArea() else { return }
        let s = GameSettingsFile.load()
        // window frame (title bar and borders) from the last placement BeamNG saved, else Wine's usual one
        var frameW = 8, frameH = 34, insetL = 4, insetT = 7
        let old = (s["WindowPlacement"] as? String ?? "").split(separator: " ").compactMap { Int($0) }
        let res = (s["GraphicDisplayResolutions"] as? String ?? "").split(separator: " ").compactMap { Int($0) }
        if old.count == 10, res.count == 2, "\(s["GraphicDisplayModes"] ?? "")" == "Window" {
            let fw = (old[9] - old[6]) - res[0], fh = (old[8] - old[7]) - res[1]
            if (0...40).contains(fw), (0...80).contains(fh) { frameW = fw; frameH = fh; insetL = fw / 2; insetT = min(fh, 7) }
        }
        let work = NSScreen.screens.first.map { m in (Int(m.visibleFrame.minX), Int(m.frame.maxY - m.visibleFrame.maxY)) } ?? (0, 0)
        let left = a.x - work.0 - insetL, top = a.y - work.1 - insetT
        let placement = "0 1 -1 -1 -1 -1 \(left) \(top) \(top + a.h + insetT) \(left + a.w + 2 * insetL)"
        GameSettingsFile.merge(["GraphicDisplayModes": "Window",
                                "GraphicDisplayResolutions": "\(a.w - frameW + 2 * insetL) \(a.h - frameH + insetT)",
                                "WindowPlacement": placement])
    }

    func setWindow(_ res: String) {
        windowRes = res
        change(["GraphicDisplayResolutions": res, "GraphicDisplayModes": "Window"])
    }

    var windowChoices: [(String, String)] {
        var list = [("1280 720", "1280 × 720"), ("1600 900", "1600 × 900"), ("1920 1080", "1920 × 1080")]
        if let f = NSScreen.main?.visibleFrame {
            let w = Int(f.width), h = Int(f.height) - 28
            list.insert(("\(w) \(h)", L("Fit screen (%ld × %ld)", w, h)), at: 0)
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
        guard state == .stopped else { message = L("Quit the game first to change mods."); refreshFogFix(); return }
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
        message = on ? L("Fog fix turned on.") : L("Fog fix turned off.")
    }

    // MARK: force feedback (PedalBox)

    static let pedalBoxID = "local.pedalbox.PedalBox"
    var pedalBoxURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.pedalBoxID) }

    /// The mod sends BeamNG's steering force to PedalBox over UDP; PedalBox drives the wheel's motor.
    func setForceFeedback(_ on: Bool) {
        guard state == .stopped else { message = L("Quit the game first to change mods."); return }
        if on && pedalBoxURL == nil { message = L("PedalBox isn't installed."); return }
        conf.ffb = on; conf.save()
        if on { installFFBMod() } else { try? FileManager.default.removeItem(at: Paths.ffbMod) }
        message = on ? L("Force feedback turned on. PedalBox starts with the game.") : L("Force feedback turned off.")
    }

    /// Copies the mod fresh each time, so a launcher update also updates the mod.
    private func installFFBMod() {
        let fm = FileManager.default
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("pedalboxFFB") else { return }
        try? fm.removeItem(at: Paths.ffbMod)
        try? fm.createDirectory(at: Paths.ffbMod.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: src, to: Paths.ffbMod)
        // the game remembers mods it has seen; make sure this one isn't switched off there
        let db = Paths.mods.appendingPathComponent("db.json")
        if var obj = (try? Data(contentsOf: db)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
           var mods = obj["mods"] as? [String: Any], var e = mods["pedalboxffb"] as? [String: Any], e["active"] as? Bool == false {
            e["active"] = true; mods["pedalboxffb"] = e; obj["mods"] = mods
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) { try? d.write(to: db) }
        }
    }

    private func startForceFeedback() {
        installFFBMod()
        guard let app = pedalBoxURL else { message = L("PedalBox isn't installed, so the wheel has no force feedback."); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.arguments = ["-ffbEnabled", "YES"]
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in
            // arguments only reach a PedalBox that wasn't open yet; tell a running one directly
            DistributedNotificationCenter.default().postNotificationName(.init("local.pedalbox.ffb.enable"), object: nil, deliverImmediately: true)
        }
    }

    // MARK: Discord

    func updateDiscord() {
        discordRunning = DiscordPresence.discordRunning
        guard state != .stopped else {
            if gameStartedAt != nil { gameStartedAt = nil; discord.clear() }
            return
        }
        if gameStartedAt == nil { gameStartedAt = Date() }
        guard conf.discord, discordRunning, let start = gameStartedAt else { return }
        var details = state == .starting ? L("Starting the game") : L("In the menus")
        var line2 = ""
        if state == .running, let rp = latestRichPresence(since: start) {
            if let r = rp.range(of: " with ", options: .backwards) {
                details = String(rp[..<r.lowerBound])
                line2 = L("Driving %@", String(rp[r.upperBound...]))
            } else {
                details = rp
            }
        }
        if conf.beammp { line2 = line2.isEmpty ? L("Multiplayer (BeamMP)") : line2 + " · BeamMP" }
        discord.update(details: details, state: line2, start: start)
    }

    func setDiscord(_ on: Bool) {
        conf.discord = on; conf.save()
        if on { updateDiscord() } else { discord.clear() }
    }

    // MARK: languages

    var gameLanguages: [String] { Languages.game(gameDir: conf.gameDir) }

    func setGameLanguage(_ key: String) {
        gameLanguage = key
        change(["userLanguage": key])
    }

    /// "" follows macOS. The launcher has to restart to switch.
    func setLauncherLanguage(_ code: String) {
        let d = UserDefaults.standard
        if code.isEmpty { d.removeObject(forKey: "AppleLanguages"); d.set(false, forKey: "launcherLanguageSet") }
        else { d.set([code], forKey: "AppleLanguages"); d.set(true, forKey: "launcherLanguageSet") }
        d.synchronize()
        let a = NSAlert()
        a.messageText = L("Restart the launcher to change its language?")
        a.addButton(withTitle: L("Restart")); a.addButton(withTitle: L("Later"))
        if a.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: add-ons (BeamMP, BeamNG.Earth, EarthNG)

    func refreshAddons() {
        let fm = FileManager.default
        beammpInstalled = fm.fileExists(atPath: Paths.beammpExe.path)
        earthInstalled = fm.fileExists(atPath: Paths.earthExe.path)
        earthngInstalled = fm.fileExists(atPath: Paths.earthngPlanet.path)
        earthngPacks = ((try? fm.contentsOfDirectory(atPath: Paths.mods.path)) ?? [])
            .filter { $0.hasPrefix("earthng_") && $0.hasSuffix(".zip") && $0 != "earthng_planet.zip" }
            .map { String($0.dropFirst(8).dropLast(4)).replacingOccurrences(of: "_", with: " ").capitalized }
            .sorted()
        if let d = try? Data(contentsOf: Paths.addonVersions),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] { addonVersions = o }
        if conf.beammp && !beammpInstalled { conf.beammp = false; conf.save() }
        if conf.earth && !earthInstalled { conf.earth = false; conf.save() }
        dxvkInstalled = fm.fileExists(atPath: Paths.dxvkDll.path)
        if conf.renderer == "dxvk" && !dxvkInstalled { conf.renderer = "d3d12"; conf.save() }
    }

    private func saveVersion(_ addon: String, _ v: String?) {
        addonVersions[addon] = v
        try? FileManager.default.createDirectory(at: Paths.addons, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: addonVersions, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: Paths.addonVersions)
        }
        updates.remove(addon)
    }

    struct Asset { let name: String; let url: URL; let size: Int; let updated: String }

    nonisolated static func latestRelease(_ repo: String) async throws -> (tag: String, assets: [Asset]) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("BeamNG-Mac-Launcher", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw LauncherError(L("GitHub didn't answer. Check your internet connection."))
        }
        let assets = (o["assets"] as? [[String: Any]] ?? []).compactMap { a -> Asset? in
            guard let n = a["name"] as? String, let u = (a["browser_download_url"] as? String).flatMap(URL.init) else { return nil }
            return Asset(name: n, url: u, size: a["size"] as? Int ?? 0, updated: String((a["updated_at"] as? String ?? "").prefix(10)))
        }
        return (o["tag_name"] as? String ?? "", assets)
    }

    static func earthAsset(_ a: [Asset]) -> Asset? {
        a.first { $0.name.hasPrefix("BeamNG.Earth-") && $0.name.hasSuffix(".exe") && !$0.name.contains("Host") }
    }

    /// Downloads to a temporary file, showing progress in the window.
    func download(_ url: URL, title: String) async throws -> URL {
        downloading = true; downloadTitle = title; downloadFraction = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let t = self?.downloadTask, t.countOfBytesExpectedToReceive > 0 {
                    self?.downloadFraction = Double(t.countOfBytesReceived) / Double(t.countOfBytesExpectedToReceive)
                }
            }
        }
        defer { downloading = false; progressTimer?.invalidate(); progressTimer = nil; downloadTask = nil }
        return try await withCheckedThrowingContinuation { cont in
            var req = URLRequest(url: url)
            req.setValue("BeamNG-Mac-Launcher", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.downloadTask(with: req) { loc, resp, err in
                if let err = err as? URLError, err.code == .cancelled { cont.resume(throwing: LauncherError(L("Download cancelled."))); return }
                if let err { cont.resume(throwing: err); return }
                guard let loc, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    cont.resume(throwing: LauncherError(L("The download failed."))); return
                }
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do { try FileManager.default.moveItem(at: loc, to: keep); cont.resume(returning: keep) }
                catch { cont.resume(throwing: error) }
            }
            downloadTask = task
            task.resume()
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    nonisolated static func sha256(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func place(_ tmp: URL, at dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: tmp, to: dst)
    }

    private func runAddonJob(_ job: @escaping @MainActor () async throws -> String) {
        guard !downloading else { return }
        Task {
            do { message = try await job() }
            catch { message = error.localizedDescription }
            refreshAddons()
        }
    }

    // MARK: renderer (pre-release)

    static let renderers: [(id: String, name: String)] = [
        ("d3d12", "Direct3D 12 · D3DMetal"), ("d3d11", "Direct3D 11 · D3DMetal"),
        ("dxvk", "Direct3D 11 · DXVK → MoltenVK"), ("vulkan", "Vulkan · MoltenVK"),
    ]
    static func rendererLong(_ id: String) -> String {
        ["d3d12": L("Direct3D 12 on D3DMetal"), "d3d11": L("Direct3D 11 on D3DMetal"),
         "dxvk": L("Direct3D 11 through DXVK"), "vulkan": L("Vulkan on MoltenVK")][id] ?? id
    }
    static func rendererShort(_ id: String) -> String {
        ["d3d12": "DX12", "d3d11": "DX11", "dxvk": "DXVK", "vulkan": "Vulkan"][id] ?? id
    }

    func setRenderer(_ id: String) {
        if id == "dxvk" && !dxvkInstalled { installDXVK(); return }
        conf.renderer = id; conf.save()
        message = state == .stopped ? L("Renderer: %@. Used from the next start.", Launcher.rendererShort(id))
                                    : L("Renderer: %@. Restart the game to use it.", Launcher.rendererShort(id))
    }

    /// DXVK-macOS (Gcenx), the "builtin" build: Wine loads it through WINEDLLPATH, nothing in the prefix changes.
    static let dxvkURL = URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz")!
    static let dxvkSHA = "810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00"

    func installDXVK() {
        runAddonJob {
            let tmp = try await self.download(Launcher.dxvkURL, title: "DXVK 1.10.3")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard Launcher.sha256(tmp) == Launcher.dxvkSHA else {
                throw LauncherError(L("The DXVK download was damaged (checksum mismatch). Try again."))
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: Paths.dxvk.path) { try fm.removeItem(at: Paths.dxvk) }
            try fm.createDirectory(at: Paths.dxvk, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["xzf", tmp.path, "-C", Paths.dxvk.path, "--strip-components", "1"]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0, fm.fileExists(atPath: Paths.dxvkDll.path) else {
                throw LauncherError(L("Couldn't unpack DXVK."))
            }
            self.saveVersion("dxvk", "1.10.3")
            self.conf.renderer = "dxvk"; self.conf.save()
            return L("DXVK installed. Renderer: DXVK from the next start.")
        }
    }

    func installBeamMP() {
        runAddonJob {
            let rel = try await Launcher.latestRelease("BeamMP/BeamMP-Launcher")
            guard let exe = rel.assets.first(where: { $0.name == "BeamMP-Launcher.exe" }) else {
                throw LauncherError(L("BeamMP's latest release has no Windows launcher."))
            }
            let tmp = try await self.download(exe.url, title: "BeamMP \(rel.tag)")
            if let sum = rel.assets.first(where: { $0.name == "BeamMP-Launcher.exe.sha256" }) {
                let (d, _) = try await URLSession.shared.data(from: sum.url)
                let want = String(decoding: d, as: UTF8.self).split(whereSeparator: { $0 == " " || $0.isNewline }).first.map { $0.lowercased() }
                if let want, want != Launcher.sha256(tmp) {
                    try? FileManager.default.removeItem(at: tmp)
                    throw LauncherError(L("The BeamMP download was damaged (checksum mismatch). Try again."))
                }
            }
            try self.place(tmp, at: Paths.beammpExe)
            self.saveVersion("beammp", rel.tag)
            self.conf.beammp = true; self.conf.save()
            return L("BeamMP %@ installed. Multiplayer is on.", rel.tag)
        }
    }

    func installEarth() {
        runAddonJob {
            let rel = try await Launcher.latestRelease("TecnaGamer/BeamNG.Earth")
            guard let exe = Launcher.earthAsset(rel.assets) else { throw LauncherError(L("BeamNG.Earth's latest release has no Windows app.")) }
            let tmp = try await self.download(exe.url, title: "BeamNG.Earth \(rel.tag)")
            try self.place(tmp, at: Paths.earthExe)
            self.saveVersion("earth", rel.tag)
            self.conf.earth = true; self.conf.save()
            return L("BeamNG.Earth %@ installed. In the game: Freeroam → BeamNG.Earth.", rel.tag)
        }
    }

    func installEarthNG() {
        runAddonJob {
            let rel = try await Launcher.latestRelease("Alezx311/earthng")
            guard let zip = rel.assets.first(where: { $0.name == "earthng_planet.zip" }) else { throw LauncherError(L("EarthNG's release has no planet mod.")) }
            let tmp = try await self.download(zip.url, title: "EarthNG")
            try self.place(tmp, at: Paths.earthngPlanet)
            self.saveVersion("earthng", zip.updated)
            return self.earthngPacks.isEmpty && !FileManager.default.fileExists(atPath: Paths.mods.appendingPathComponent("earthng_albania.zip").path)
                ? L("EarthNG installed. It also needs a map pack: get Albania or add one you downloaded.")
                : L("EarthNG installed. In the game: Freeroam → EarthNG - Planet.")
        }
    }

    func installEarthNGAlbania() {
        runAddonJob {
            let rel = try await Launcher.latestRelease("Alezx311/earthng")
            guard let zip = rel.assets.first(where: { $0.name == "earthng_albania.zip" }) else { throw LauncherError(L("That map pack is no longer on GitHub.")) }
            let tmp = try await self.download(zip.url, title: "EarthNG Albania")
            try self.place(tmp, at: Paths.mods.appendingPathComponent(zip.name))
            return L("Map pack added: %@.", "Albania")
        }
    }

    func addEarthNGPack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = true
        panel.message = L("Choose EarthNG map packs (earthng_<country>.zip)")
        panel.directoryURL = Paths.home.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK else { return }
        var added: [String] = []
        for url in panel.urls {
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix("earthng_"), name != "earthng_planet.zip" else { continue }
            let dst = Paths.mods.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            if (try? FileManager.default.copyItem(at: url, to: dst)) != nil { added.append(url.lastPathComponent) }
        }
        refreshAddons()
        message = added.isEmpty ? L("No EarthNG map pack chosen (the file name must start with earthng_).")
                                : L("Map pack added: %@.", added.joined(separator: ", "))
    }

    func removeAddon(_ addon: String) {
        guard state == .stopped else { message = L("Quit the game first."); return }
        let fm = FileManager.default
        func trash(_ u: URL) { if fm.fileExists(atPath: u.path) { try? fm.trashItem(at: u, resultingItemURL: nil) } }
        switch addon {
        case "beammp":
            trash(Paths.beammpExe.deletingLastPathComponent())
            trash(Paths.mods.appendingPathComponent("multiplayer"))
            conf.beammp = false
        case "earth":
            trash(Paths.earthExe.deletingLastPathComponent())
            trash(Paths.earthMod)
            conf.earth = false
        default:
            trash(Paths.earthngPlanet)
            for f in (try? fm.contentsOfDirectory(atPath: Paths.mods.path)) ?? [] where f.hasPrefix("earthng_") && f.hasSuffix(".zip") {
                trash(Paths.mods.appendingPathComponent(f))
            }
        }
        conf.save()
        saveVersion(addon, nil)
        refreshAddons()
        message = L("Removed (moved to the Trash).")
    }

    /// Notes which installed add-ons have a newer GitHub release (BeamMP updates itself).
    func checkAddonUpdates() async {
        if earthInstalled, let rel = try? await Launcher.latestRelease("TecnaGamer/BeamNG.Earth"),
           !rel.tag.isEmpty, rel.tag != addonVersions["earth"] { updates.insert("earth") }
        if earthngInstalled, let rel = try? await Launcher.latestRelease("Alezx311/earthng"),
           let zip = rel.assets.first(where: { $0.name == "earthng_planet.zip" }),
           !zip.updated.isEmpty, zip.updated != addonVersions["earthng"] { updates.insert("earthng") }
    }

    func setMultiplayer(_ on: Bool) {
        if on && !beammpInstalled { installBeamMP(); return }
        conf.beammp = on; conf.save()
        message = state == .stopped ? (on ? L("Multiplayer on: BeamMP starts with the game.") : L("Single player."))
                                    : L("Takes effect next time the game starts.")
    }

    func setEarth(_ on: Bool) {
        if on && !earthInstalled { installEarth(); return }
        conf.earth = on; conf.save()
        message = state == .stopped ? (on ? L("BeamNG.Earth starts with the game. In the game: Freeroam → BeamNG.Earth.") : L("BeamNG.Earth off."))
                                    : L("Takes effect next time the game starts.")
    }

    /// BeamMP finds the game through BeamNG.Drive.ini (the game writes it too, but only once it has run).
    func writeBeamNGIni() {
        let win = "Z:" + conf.gameDir.replacingOccurrences(of: "/", with: "\\") + "\\"
        var lines = ((try? String(contentsOf: Paths.beamngIni, encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("installPath") }
        lines.append("installPath = \(win)")
        try? FileManager.default.createDirectory(at: Paths.beamngIni.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: Paths.beamngIni, atomically: true, encoding: .utf8)
    }

    // MARK: game control

    func play() {
        guard setupComplete else { message = L("Finish setup first."); return }
        if conf.beammp && !beammpInstalled { conf.beammp = false }
        if conf.earth && !earthInstalled { conf.earth = false }
        // Wine only passes wheels it knows to the game; tell it about the ones plugged in now
        devices = ControllerScanner.scan()
        conf.hidraw = devices.filter { $0.kind == .wheel }.compactMap { d -> String? in
            let p = d.id.split(separator: ":").compactMap { Int($0, radix: 16) }
            return p.count == 2 ? String(format: "0x%04X/0x%04X", p[0], p[1]) : nil
        }.joined(separator: ",")
        conf.save()
        if conf.beammp { writeBeamNGIni() }
        if !pendingChanges.isEmpty { GameSettingsFile.merge(pendingChanges); pendingChanges = [:] }
        applySpan()
        if conf.ffb { startForceFeedback() }
        runShell(Paths.bin.appendingPathComponent("launch.sh"), wait: false)
        state = .starting; lastState = .starting
        message = L("Starting BeamNG…")
    }

    func quitGame(then: (@MainActor () -> Void)? = nil) {
        busy = true; message = L("Closing BeamNG…")
        Task.detached {
            runShell(Paths.bin.appendingPathComponent("quit.sh"))
            await MainActor.run {
                self.busy = false
                self.tick()
                self.message = self.state == .stopped ? L("BeamNG closed.") : L("BeamNG is still closing…")
                then?()
            }
        }
    }

    func restart() { quitGame { self.play() } }

    func clearShaderCache() {
        guard state == .stopped else { message = L("Quit the game first."); return }
        let fm = FileManager.default
        var removed = 0
        for url in [Paths.userRoot.appendingPathComponent("temp/shaders"),
                    Paths.userCache.appendingPathComponent("d3dm/BeamNG.drive.x64.exe")] where fm.fileExists(atPath: url.path) {
            if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { removed += 1 }
        }
        message = removed > 0 ? L("Shader caches moved to the Trash. The next start will be slower while they rebuild.")
                              : L("No shader cache to clear.")
    }

    func resetDefaults() {
        guard state == .stopped else { message = L("Quit the game first."); return }
        GameSettingsFile.backup(tag: "launcher-reset")
        var p = gamePresets(gameDir: conf.gameDir)["High"] ?? [:]
        p["GraphicOverallQuality"] = "High"
        p["GraphicAntialiasType"] = "fsr3"; p["GraphicAntialias"] = 4
        p["GraphicUpscalingQuality"] = 1.0; p["GraphicUpscalingSharpness"] = 0.3
        p["GraphicDisplayModes"] = "Window"
        if let f = NSScreen.main?.visibleFrame { p["GraphicDisplayResolutions"] = "\(Int(f.width)) \(Int(f.height) - 28)" }
        GameSettingsFile.merge(p)
        conf.fixTrees = true; conf.metal4 = true; conf.fpsHUD = false; conf.extraArgs = ""; conf.renderer = "d3d12"
        conf.gptkVersion = "current"; conf.save()
        if fogFix { setFogFix(false) }
        loadGraphics()
        message = L("Back to recommended settings (High, native resolution, FSR 3, windowed). Old settings were backed up.")
    }

    // MARK: setup actions

    func chooseGameDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = L("Choose the BeamNG.drive folder (the one that contains BeamNG.drive.exe)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("BeamNG.drive.exe").path) {
            conf.gameDir = url.path; conf.save(); loadGraphics()
            message = L("Game folder set.")
        } else {
            message = L("That folder doesn't contain BeamNG.drive.exe.")
        }
    }

    func installGPTK() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage]
        panel.message = L("Choose Apple's \"Evaluation environment for Windows games\" .dmg")
        panel.directoryURL = Paths.home.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; message = L("Installing GPTK…")
        Task.detached {
            let (code, out) = runShell(Paths.bin.appendingPathComponent("install-gptk.sh"), [url.path])
            await MainActor.run {
                self.busy = false
                self.message = code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : L("GPTK install failed: %@", out)
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
        message = state == .stopped ? L("Using GPTK %@.", v) : L("Using GPTK %@ from the next start.", v)
    }

    func importRuntime() {
        guard state == .stopped else { message = L("Quit the game first."); return }
        busy = true; message = L("Importing Wine from GameHub… (this takes a few seconds)")
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
    var label: String { state == .running ? L("Running") : (state == .starting ? L("Starting…") : L("Not running")) }
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
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle) }
            }
        }
    }
}

struct Caption: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateChecker.shared.start(repo: "j0di3x/beamng-mac-launcher", appName: "BeamNG Launcher")
        NSWindow.allowsAutomaticWindowTabbing = false
        lockWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.lockWindows() }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.lockWindows() }
        }
    }

    /// The window is a fixed 980 × 600: no resizing, no zoom, no full screen.
    @MainActor func lockWindows() {
        for w in NSApp.windows where w.styleMask.contains(.titled) {
            w.styleMask.remove(.resizable)
            w.collectionBehavior.remove(.fullScreenPrimary)
            w.collectionBehavior.insert(.fullScreenNone)
            w.standardWindowButton(.zoomButton)?.isEnabled = false
        }
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
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 600)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(L("Check for Updates…")) { Task { await UpdateChecker.shared.check(manual: true) } }
            }
        }
    }
}
