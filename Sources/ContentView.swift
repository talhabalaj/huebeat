import SwiftUI

struct ContentView: View {
    let controller: LightsController
    @State private var config = AppConfig()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 320)
        } detail: {
            dashboard
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Huebeat")
                    .font(.system(size: 26, weight: .semibold))
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            DongleStatusView(bridge: controller.bridge)

            Toggle("Dry run", isOn: $config.dryRun)
                .disabled(controller.isRunning)

            VStack(alignment: .leading, spacing: 12) {
                Text("Mode")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Preset", selection: $config.preset) {
                    ForEach(MusicPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(controller.isRunning)
                .onChange(of: config.preset) { _, _ in
                    config.applyPresetDefaults()
                }

                Picker("Animation", selection: $config.animationStyle) {
                    ForEach(AnimationStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .disabled(controller.isRunning)
            }

            tuningControls

            Spacer(minLength: 16)

            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if controller.needsAudioPermission {
                    Button("Open Privacy Settings", action: controller.openAudioPrivacySettings)
                }
            }

            Button(action: toggleRun) {
                Label(buttonTitle, systemImage: controller.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(controller.isTransitioning)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(20)
    }

    private var tuningControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tuning")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ConfigSlider(title: "Gain", value: $config.gain, range: 1...30, step: 0.5, format: "%.1f")
            ConfigSlider(title: "Max Hz", value: $config.maxHz, range: 0.5...8, step: 0.5, format: "%.1f")
            ConfigSlider(title: "Floor", value: $config.floor, range: 0...0.1, step: 0.001, format: "%.3f")
            ConfigSlider(title: "Beat", value: $config.beatThreshold, range: 0.5...5, step: 0.1, format: "%.1f")
            Toggle("Pulse brightness", isOn: $config.pulseBrightness)
        }
        .disabled(controller.isRunning)
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                ColorVisualizer(update: controller.currentColor, isRunning: controller.isRunning)
                    .frame(width: 360, height: 360)

                VStack(alignment: .leading, spacing: 16) {
                    metrics
                    quickActions
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(28)

            Divider()

            LogView(lines: controller.logLines, onClear: controller.clearLog)
                .frame(minHeight: 210)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var metrics: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            GridRow {
                MetricView(label: "Hue", value: controller.currentColor.map { "\($0.h)" } ?? "---")
                MetricView(label: "Saturation", value: controller.currentColor.map { "\($0.s)" } ?? "---")
                MetricView(label: "Value", value: controller.currentColor.map { "\($0.v)" } ?? "---")
            }
            GridRow {
                MetricView(label: "Lights", value: "\(controller.bridge.lights.count)")
                MetricView(label: "Sweep", value: controller.bridge.lastSweepMs.map { "\($0) ms" } ?? "---")
                MetricView(label: "Missed", value: "\(controller.bridge.failedSends)")
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Colors")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ColorButton(name: "Red", color: .red) { controller.sendQuickColor(hue: 0) }
                ColorButton(name: "Green", color: .green) { controller.sendQuickColor(hue: 120) }
                ColorButton(name: "Blue", color: .blue) { controller.sendQuickColor(hue: 240) }
                Button(action: controller.restoreLights) {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            }
            .disabled(controller.isRunning || !controller.bridge.isReady)
        }
    }

    private func toggleRun() {
        controller.isRunning ? controller.stop() : controller.start(config: config)
    }

    private var statusText: String {
        if controller.isTransitioning {
            return controller.isRunning ? "Stopping audio" : "Starting audio"
        }
        return controller.isRunning ? "Listening to system audio" : "Ready"
    }

    private var buttonTitle: String {
        if controller.isTransitioning {
            return controller.isRunning ? "Stopping" : "Starting"
        }
        return controller.isRunning ? "Stop" : "Start"
    }
}

struct ConfigSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct ColorVisualizer: View {
    let update: ColorUpdate?
    let isRunning: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(update?.color ?? Color(nsColor: .quaternaryLabelColor))
                .overlay(
                    Circle()
                        .stroke(.white.opacity(update?.beat == true ? 0.92 : 0.18), lineWidth: update?.beat == true ? 8 : 1)
                        .padding(update?.beat == true ? 10 : 0)
                )
                .shadow(color: (update?.color ?? .black).opacity(update == nil ? 0.16 : 0.55), radius: update?.beat == true ? 38 : 20)
                .animation(.spring(response: 0.16, dampingFraction: 0.68), value: update)

            VStack(spacing: 10) {
                Image(systemName: isRunning ? "waveform" : "lightbulb")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white.opacity(update == nil ? 0.45 : 0.9))
                Text(update?.beat == true ? "BEAT" : (isRunning ? "LIVE" : "IDLE"))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(update == nil ? 0.45 : 0.9))
            }
        }
        .padding(18)
    }
}

struct MetricView: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: 118, alignment: .leading)
    }
}

struct ColorButton: View {
    let name: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                Text(name)
            }
            .frame(minWidth: 82)
        }
    }
}

struct LogView: View {
    let lines: [String]
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClear) {
                    Label("Clear", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Clear log")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct DongleStatusView: View {
    let bridge: ZigbeeBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sonoff Dongle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Circle()
                    .fill(indicator)
                    .frame(width: 9, height: 9)
                Text(title)
                Spacer()
                if bridge.state == .connecting {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.callout)
            if case .failed(let message) = bridge.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(bridge.lights) { light in
                Label(light.name, systemImage: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !bridge.isRunning {
                Button(action: bridge.connect) {
                    Label("Connect", systemImage: "cable.connector")
                }
            }
        }
    }

    private var title: String {
        switch bridge.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .ready(let port): "Connected · \(port.replacingOccurrences(of: "/dev/cu.", with: ""))"
        case .failed: "Not connected"
        }
    }

    private var indicator: Color {
        switch bridge.state {
        case .ready: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .gray
        }
    }
}
