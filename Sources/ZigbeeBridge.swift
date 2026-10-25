import Foundation
import Observation

struct ZigbeeLight: Identifiable, Hashable, Decodable {
    let ieee: String
    let name: String
    var id: String { ieee }
}

/// Owns the bundled Node helper that drives the Sonoff (EFR32/Ember) dongle through zigbee-herdsman.
@Observable
final class ZigbeeBridge {
    enum State: Equatable {
        case disconnected
        case connecting
        case ready(port: String)
        case failed(String)
    }

    private(set) var state: State = .disconnected
    private(set) var lights: [ZigbeeLight] = []
    private(set) var lastSweepMs: Int?
    private(set) var failedSends = 0
    /// Off while Huebeat is in the background: the sweep stats change every sweep and would re-render the stats panel.
    @ObservationIgnored var publishesStats = true {
        didSet { if publishesStats { lastSweepMs = pendingSweepMs; failedSends = pendingFailedSends } }
    }
    @ObservationIgnored private var pendingSweepMs: Int?
    @ObservationIgnored private var pendingFailedSends = 0
    var onLog: ((String) -> Void)?
    var onReady: (() -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()

    var isReady: Bool {
        if case .ready = state { true } else { false }
    }

    var isRunning: Bool { process?.isRunning == true }

    /// `~/Library/Application Support/Huebeat/Zigbee`: network key, device database and coordinator backup.
    static var dataDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Huebeat/Zigbee", directoryHint: .isDirectory)
    }

    private static let networkFiles = ["network.json", "database.db", "coordinator-backup.json"]

    func connect() {
        guard process == nil else { return }
        state = .connecting
        lights = []
        do {
            try Self.importLegacyNetworkIfNeeded()
            try launch()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// `exactLevel` always sends brightness; music only sends it when it moved noticeably.
    /// `transition` is in tenths of a second; the bulb fades there itself, so smooth modes need no extra frames.
    func send(xy: ColorMath.XY, level: Int?, exactLevel: Bool = false, transition: Int = 0) {
        var message: [String: Any] = ["cmd": "color", "x": xy.x, "y": xy.y, "exactLevel": exactLevel, "transition": transition]
        if let level { message["level"] = level }
        write(message)
    }

    /// Color temperature in mireds: 153 is cool daylight, 500 is warm candlelight.
    func sendWhite(mireds: Int, level: Int) {
        write(["cmd": "white", "mireds": mireds, "level": level, "exactLevel": true])
    }

    /// Remembers the bulbs' current state so `restore()` can bring it back after music.
    func snapshot() {
        write(["cmd": "snapshot"])
    }

    /// Adds a line to ~/Library/Logs/Huebeat/helper.log.
    func trace(_ line: String) {
        write(["cmd": "trace", "line": line])
    }

    func restore() {
        write(["cmd": "restore"])
    }

    /// Restores the bulbs, closes the serial port and waits for the helper to exit.
    func shutdown() async {
        guard let process, process.isRunning else { return }
        write(["cmd": "quit"])
        for _ in 0..<80 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { process.terminate() }
    }

    // MARK: - Process

    private func launch() throws {
        guard let script = Bundle.main.url(forResource: "huebeat-zigbee", withExtension: "cjs", subdirectory: "Helper") else {
            throw HuebeatError.bridge("The Zigbee helper is missing from the app bundle.")
        }
        guard let node = Self.findNode() else {
            throw HuebeatError.bridge("Node.js wasn't found. Install it with `brew install node`.")
        }

        let process = Process()
        process.executableURL = node
        process.arguments = [script.path, "--data", Self.dataDirectory.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF reads empty forever; without this the handler spins until the termination handler runs.
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.exited(process: finished, status: status) }
        }

        try process.run()
        self.process = process
        stdin = input.fileHandleForWriting
    }

    private func exited(process finished: Process, status: Int32) {
        guard finished === process else { return }
        (finished.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdin = nil
        lights = []
        if case .failed = state { return }
        state = status == 0 ? .disconnected : .failed("Zigbee helper exited (\(status)).")
    }

    private func write(_ message: [String: Any]) {
        guard let stdin, process?.isRunning == true,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? stdin.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private struct Event: Decodable {
        let event: String
        let message: String?
        let port: String?
        let lights: [ZigbeeLight]?
        let ms: Int?
        let failed: Int?
    }

    private func handle(line: Data) {
        guard let event = try? JSONDecoder().decode(Event.self, from: line) else {
            if let text = String(data: line, encoding: .utf8), !text.isEmpty { onLog?(text) }
            return
        }
        switch event.event {
        case "ready":
            lights = event.lights ?? []
            state = .ready(port: event.port ?? "")
            onLog?("Dongle ready on \(event.port ?? "?") with \(lights.count) lights.")
            onReady?()
        case "sent":
            pendingSweepMs = event.ms
            pendingFailedSends += event.failed ?? 0
            if publishesStats {
                lastSweepMs = pendingSweepMs
                failedSends = pendingFailedSends
            }
        case "snapshot":
            onLog?("Saved the lights' current colors.")
        case "restored":
            onLog?("Lights restored to their previous colors.")
        case "error":
            let message = event.message ?? "Unknown error"
            if !isReady { state = .failed(message) }
            onLog?("Zigbee: \(message)")
        default:
            if let message = event.message { onLog?(message) }
        }
    }

    // MARK: - Setup

    private static func findNode() -> URL? {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node", NSHomeDirectory() + "/.volta/bin/node"]
        where fm.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        // GUI apps don't inherit the shell PATH; ask a login shell for nvm/asdf/mise installs.
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fm.isExecutableFile(atPath: path) ? URL(filePath: path) : nil
    }

    /// First launch: copy (never move) the network paired by the setup scripts in ~/.local/share/sonoff-zigbee.
    private static func importLegacyNetworkIfNeeded() throws {
        let fm = FileManager.default
        let target = dataDirectory
        if networkFiles.allSatisfy({ fm.fileExists(atPath: target.appending(path: $0).path) }) { return }

        let legacy = URL(filePath: NSHomeDirectory()).appending(path: ".local/share/sonoff-zigbee", directoryHint: .isDirectory)
        guard networkFiles.allSatisfy({ fm.fileExists(atPath: legacy.appending(path: $0).path) }) else {
            throw HuebeatError.bridge("No paired Zigbee network found. Expected network.json, database.db and coordinator-backup.json in \(target.path).")
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in networkFiles where !fm.fileExists(atPath: target.appending(path: name).path) {
            try fm.copyItem(at: legacy.appending(path: name), to: target.appending(path: name))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.appending(path: name).path)
        }
    }
}
