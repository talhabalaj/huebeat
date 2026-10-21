import Foundation
import Observation

@Observable
final class LightsController {
    private(set) var isRunning = false
    private(set) var isTransitioning = false
    private(set) var currentColor: ColorUpdate?
    private(set) var logLines: [String] = []
    var lastError: String?

    let bridge = ZigbeeBridge()

    private var capture: NativeAudioCapture?
    private var captureSession: UUID?
    private var mapper: AudioColorMapper?
    private var config = AppConfig()
    private var lastSent = Date.distantPast
    private var lastQueuedColor: ColorUpdate?

    init() {
        bridge.onLog = { [weak self] line in self?.appendLog(line) }
    }

    func start(config: AppConfig) {
        guard !isRunning, !isTransitioning else { return }
        guard config.dryRun || bridge.isReady else {
            lastError = "Connect the Sonoff dongle first, or turn on Dry run."
            return
        }
        isTransitioning = true
        self.config = config
        lastError = nil
        currentColor = nil
        lastQueuedColor = nil
        lastSent = .distantPast
        mapper = AudioColorMapper(config: config)

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

    func sendQuickColor(hue: Double) {
        guard bridge.isReady, !isRunning else { return }
        bridge.send(xy: ColorMath.xy(hue: hue, saturation: 1), level: 254)
        appendLog("Sent hue \(Int(hue))°.")
    }

    func restoreLights() {
        bridge.restore()
    }

    /// Called on quit: stop listening, put the bulbs back and release the serial port.
    func shutdown() async {
        if isRunning { await tearDown() }
        await bridge.shutdown()
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

        let now = Date()
        let interval = 1.0 / max(0.5, config.maxHz)
        let hueDelta = abs(update.h - (lastQueuedColor?.h ?? -999))
        let valueDelta = abs(update.v - (lastQueuedColor?.v ?? -999))
        // A beat always goes out; otherwise skip frames that wouldn't visibly change the bulbs.
        guard now.timeIntervalSince(lastSent) >= interval, update.beat || hueDelta >= 4 || valueDelta >= 25 else { return }
        lastSent = now
        lastQueuedColor = update
        guard !config.dryRun else { return }
        let level = config.pulseBrightness ? ColorMath.level(value: update.v) : nil
        bridge.send(xy: ColorMath.xy(hue: Double(update.h), saturation: Double(update.s) / 1000), level: level)
    }

    private func appendLog(_ line: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }
}
