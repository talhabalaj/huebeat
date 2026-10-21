import Accelerate
import AppKit
import CoreGraphics
import Observation
import SwiftUI

@Observable
final class LightsController {
    private(set) var isRunning = false
    private(set) var isTransitioning = false
    private(set) var currentColor: ColorUpdate?
    private(set) var logLines: [String] = []
    var lastError: String?
    private(set) var needsAudioPermission = false

    let bridge = ZigbeeBridge()

    private var capture: NativeAudioCapture?
    private var captureSession: UUID?
    private var mapper: AudioColorMapper?
    private var config = AppConfig()
    private var lastSent = Date.distantPast
    private var lastQueuedColor: ColorUpdate?
    private var stats = Stats()

    /// Rolling numbers logged every few seconds, so "the lights aren't moving" can be traced to audio or sending.
    private struct Stats {
        var started = Date()
        var buffers = 0
        var peak: Float = 0
        var beats = 0
        var sent = 0
    }

    init() {
        bridge.onLog = { [weak self] line in self?.appendLog(line) }
    }

    func start(config: AppConfig) {
        guard !isRunning, !isTransitioning else { return }
        guard config.dryRun || bridge.isReady else {
            lastError = "Connect the Sonoff dongle first, or turn on Dry run."
            return
        }
        // ScreenCaptureKit audio needs Screen & System Audio Recording. Requesting it shows the system
        // prompt the first time and lists Huebeat in Privacy settings; afterwards only the user can flip it.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            needsAudioPermission = true
            lastError = "Huebeat needs Screen & System Audio Recording to hear your music. Turn it on in Privacy settings, then press Start."
            return
        }
        needsAudioPermission = false
        isTransitioning = true
        self.config = config
        lastError = nil
        currentColor = nil
        lastQueuedColor = nil
        lastSent = .distantPast
        stats = Stats()
        mapper = AudioColorMapper(config: config)
        if !config.dryRun { bridge.snapshot() }

        Task {
            do {
                let capture = makeCapture()
                self.capture = capture
                try await capture.start(sampleRate: config.sampleRate, channels: 2)
                isRunning = true
                isTransitioning = false
                appendLog(config.dryRun ? "Listening (dry run, lights untouched)." : "Listening to system audio.")
            } catch {
                lastError = error.localizedDescription
                if error.localizedDescription.contains("TCC") {
                    needsAudioPermission = true
                    lastError = "macOS blocked audio capture. Turn on Huebeat under Screen & System Audio Recording, then press Start."
                }
                appendLog("Start failed: \(error.localizedDescription)")
                await tearDown()
            }
        }
    }

    func stop() {
        guard isRunning, !isTransitioning else { return }
        isTransitioning = true
        Task { await tearDown() }
    }

    /// Manual control while music is off. `brightness` is 0...1.
    func setManualColor(_ color: Color, brightness: Double) {
        guard bridge.isReady, !isRunning,
              let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        // The picker's own brightness would double up with the slider, so send the color at full value.
        var hue: CGFloat = 0, saturation: CGFloat = 0, value: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha)
        let xy = ColorMath.xy(hue: Double(hue) * 360, saturation: Double(saturation))
        bridge.send(xy: xy, level: ColorMath.level(brightness: brightness), exactLevel: true)
    }

    func setManualWhite(mireds: Double, brightness: Double) {
        guard bridge.isReady, !isRunning else { return }
        bridge.sendWhite(mireds: Int(mireds.rounded()), level: ColorMath.level(brightness: brightness))
    }

    /// Called on quit: stop listening, put the bulbs back and release the serial port.
    func shutdown() async {
        if isRunning { await tearDown() }
        await bridge.shutdown()
    }

    func openAudioPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func clearLog() {
        logLines.removeAll()
    }

    // Callbacks from a torn-down capture can still be in flight; the session ID filters them out.
    private func makeCapture() -> NativeAudioCapture {
        let session = UUID()
        captureSession = session
        return NativeAudioCapture { [weak self] samples, channels in
            Task { @MainActor in
                guard let self, self.captureSession == session else { return }
                self.handle(samples: samples, channels: channels)
            }
        } onError: { [weak self] message in
            Task { @MainActor in
                guard let self, self.captureSession == session else { return }
                self.lastError = message
                self.appendLog("Audio capture stopped: \(message)")
                await self.tearDown()
            }
        }
    }

    private func tearDown() async {
        let capture = self.capture
        self.capture = nil
        captureSession = nil
        mapper = nil
        await capture?.stop()
        if !config.dryRun { bridge.restore() }
        isRunning = false
        isTransitioning = false
        appendLog("Stopped.")
    }

    private func handle(samples: [Float], channels: Int) {
        guard let mapper else { return }
        let update = mapper.map(samples: samples, channels: channels)
        currentColor = update
        recordStats(samples: samples, beat: update.beat)

        let now = Date()
        let interval = 1.0 / max(0.5, config.maxHz)
        let hueDelta = abs(update.h - (lastQueuedColor?.h ?? -999))
        let valueDelta = abs(update.v - (lastQueuedColor?.v ?? -999))
        let sinceLast = now.timeIntervalSince(lastSent)
        // Beats jump the queue (one bulb sweep is ~135 ms); other frames are rate-limited and must visibly differ.
        let due = update.beat ? sinceLast >= 0.15 : sinceLast >= interval && (hueDelta >= 4 || valueDelta >= 25)
        guard due else { return }
        lastSent = now
        lastQueuedColor = update
        stats.sent += 1
        guard !config.dryRun else { return }
        let level = config.pulseBrightness ? ColorMath.level(value: update.v) : nil
        bridge.send(
            xy: ColorMath.xy(hue: Double(update.h), saturation: Double(update.s) / 1000),
            level: level,
            transition: update.beat ? 0 : config.animationStyle.bulbTransition
        )
    }

    private func recordStats(samples: [Float], beat: Bool) {
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        stats.buffers += 1
        stats.peak = max(stats.peak, peak)
        if beat { stats.beats += 1 }
        let elapsed = Date().timeIntervalSince(stats.started)
        guard elapsed >= 5 else { return }
        let line = String(format: "Audio peak %.3f · %d buffers · %d beats · %d colors sent in %.0fs", stats.peak, stats.buffers, stats.beats, stats.sent, elapsed)
        appendLog(stats.peak < 0.002 ? line + " (silent: is anything playing?)" : line)
        bridge.trace(line)
        stats = Stats()
    }

    private func appendLog(_ line: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }
}
