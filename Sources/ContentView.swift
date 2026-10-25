import SwiftUI

/// Colors lifted from the app icon: magenta rim, orange arcs, cyan core.
enum Brand {
    static let pink = Color(red: 1, green: 0.24, blue: 0.72)
    static let orange = Color(red: 1, green: 0.58, blue: 0.24)
    static let cyan = Color(red: 0.26, green: 0.8, blue: 1)
    static let gradient = LinearGradient(colors: [pink, orange, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension LightsController {
    func toggleRun() {
        isRunning ? stop() : start(config: config)
    }

    var statusText: String {
        if isTransitioning { return isRunning ? "Stopping…" : "Starting…" }
        if !isRunning { return "Ready" }
        return config.dryRun ? "Listening · dry run" : "Listening to your Mac"
    }
}

extension ZigbeeBridge {
    var statusTitle: String {
        switch state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .ready: lights.count == 1 ? "1 light" : "\(lights.count) lights"
        case .failed: "Not connected"
        }
    }

    var statusColor: Color {
        switch state {
        case .ready: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .gray
        }
    }
}

struct ContentView: View {
    let controller: LightsController
    @State private var showLog = false

    var body: some View {
        HStack(spacing: 0) {
            stage
            SettingsColumn(controller: controller)
                .frame(width: 330)
        }
        .background { AmbientBackground(controller: controller) }
        .preferredColorScheme(.dark)
    }

    private var stage: some View {
        VStack(spacing: 0) {
            // Clears the traffic lights and leaves an empty strip to drag the window by.
            HStack {
                Spacer()
                DongleBadge(bridge: controller.bridge)
            }
            .padding(.top, 14)
            .padding(.horizontal, 22)
            .frame(height: 52)

            Spacer(minLength: 12)

            LiveOrb(controller: controller)
                .frame(width: 240, height: 240)

            VStack(spacing: 6) {
                Text("Huebeat")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(controller.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .padding(.top, 28)

            runButton
                .padding(.top, 22)

            errorBox
                .padding(.top, 14)
                .frame(maxWidth: 420)

            Spacer(minLength: 16)

            LiveStats(controller: controller)
                .padding(.horizontal, 22)

            logDrawer
        }
        .frame(maxWidth: .infinity)
    }

    private var runButton: some View {
        Button(action: controller.toggleRun) {
            Label(controller.isRunning ? "Stop" : "Start", systemImage: controller.isRunning ? "stop.fill" : "play.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 168, height: 48)
                .background {
                    Capsule().fill(controller.isRunning ? AnyShapeStyle(.white.opacity(0.12)) : AnyShapeStyle(Brand.gradient))
                }
                .overlay { Capsule().strokeBorder(.white.opacity(0.18)) }
                .shadow(color: Brand.pink.opacity(controller.isRunning ? 0 : 0.45), radius: 16, y: 4)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .opacity(controller.isTransitioning ? 0.6 : 1)
        .disabled(controller.isTransitioning)
        .keyboardShortcut(.return, modifiers: [])
    }

    @ViewBuilder
    private var errorBox: some View {
        if let error = controller.lastError {
            VStack(spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if controller.needsAudioPermission {
                    Button("Open Privacy Settings", action: controller.openAudioPrivacySettings)
                        .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var logDrawer: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { showLog.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.up")
                        .rotationEffect(.degrees(showLog ? 180 : 0))
                    Text("Activity")
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showLog {
                LogView(lines: controller.logLines, onClear: controller.clearLog)
                    .frame(height: 170)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// Reads the live color in its own view so live color updates don't re-render the settings column.
/// No implicit animation: a full-window gradient fade that never settles between color updates kept
/// SwiftUI and WindowServer redrawing every frame.
private struct AmbientBackground: View {
    let controller: LightsController

    var body: some View {
        let glow = controller.currentColor?.color ?? Brand.pink.opacity(controller.isRunning ? 0.5 : 0.22)
        ZStack {
            Color(red: 0.05, green: 0.045, blue: 0.07)
            RadialGradient(colors: [glow.opacity(0.55), .clear], center: UnitPoint(x: 0.36, y: 0.42), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Brand.cyan.opacity(0.12), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}

private struct LiveOrb: View {
    let controller: LightsController

    var body: some View {
        ColorVisualizer(update: controller.currentColor, isRunning: controller.isRunning)
    }
}

private struct DongleBadge: View {
    let bridge: ZigbeeBridge

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(bridge.statusColor).frame(width: 7, height: 7)
                .shadow(color: bridge.statusColor, radius: 4)
            Text(bridge.statusTitle)
            if bridge.state == .connecting {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct LiveStats: View {
    let controller: LightsController

    var body: some View {
        let color = controller.currentColor
        HStack(spacing: 0) {
            Stat(label: "Hue", value: color.map { "\($0.h)°" })
            Stat(label: "Saturation", value: color.map { "\($0.s / 10)%" })
            Stat(label: "Brightness", value: color.map { "\($0.v / 10)%" })
            Stat(label: "Sweep", value: controller.bridge.lastSweepMs.map { "\($0) ms" })
            Stat(label: "Missed", value: "\(controller.bridge.failedSends)")
        }
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

private struct Stat: View {
    let label: String
    let value: String?

    var body: some View {
        VStack(spacing: 3) {
            Text(value ?? "—")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsColumn: View {
    @Bindable var controller: LightsController

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card("Mode", hint: lockHint) {
                    HStack(spacing: 8) {
                        ForEach(MusicPreset.allCases) { preset in
                            PresetTile(preset: preset, isSelected: controller.config.preset == preset) {
                                controller.config.preset = preset
                            }
                        }
                    }
                    Picker(selection: $controller.config.animationStyle) {
                        ForEach(AnimationStyle.allCases) { style in
                            Label(style.label, systemImage: style.symbol).tag(style)
                        }
                    } label: {
                        Text("Animation").foregroundStyle(.secondary)
                    }
                    .pickerStyle(.menu)
                }
                .disabled(controller.isRunning)

                Card("Manual light", hint: controller.isRunning ? "Off while music plays" : nil) {
                    ManualLightView(controller: controller)
                        .disabled(controller.isRunning || !controller.bridge.isReady)
                }

                Card("Tuning", hint: lockHint) {
                    ConfigSlider(title: "Gain", value: $controller.config.gain, range: 1...30, step: 0.5, format: "%.1f")
                    ConfigSlider(title: "Max rate", value: $controller.config.maxHz, range: 0.5...8, step: 0.5, format: "%.1f Hz")
                    ConfigSlider(title: "Noise floor", value: $controller.config.floor, range: 0...0.1, step: 0.001, format: "%.3f")
                    ConfigSlider(title: "Beat threshold", value: $controller.config.beatThreshold, range: 0.5...5, step: 0.1, format: "%.1f")
                    Divider().opacity(0.5)
                    Toggle("Pulse brightness", isOn: $controller.config.pulseBrightness)
                    Toggle("Dry run (lights untouched)", isOn: $controller.config.dryRun)
                }
                .disabled(controller.isRunning)

                Card("Sonoff dongle") {
                    DongleStatusView(bridge: controller.bridge)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 52)
            .padding(.bottom, 16)
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .scrollIndicators(.never)
        .background(.black.opacity(0.28))
        .overlay(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
        }
    }

    private var lockHint: String? {
        controller.isRunning ? "Stop to change" : nil
    }
}

private struct Card<Content: View>: View {
    let title: String
    let hint: String?
    let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
                Spacer()
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.07))
        }
    }
}

private struct PresetTile: View {
    let preset: MusicPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.secondary))
                Text(preset.label)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(.white.opacity(isSelected ? 0.1 : 0.03), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.white.opacity(0.06)), lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

struct ConfigSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: range, step: step)
                .tint(Brand.pink)
        }
    }
}

struct LogView: View {
    let lines: [String]
    let onClear: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(.black.opacity(0.35))
            .overlay(alignment: .topTrailing) {
                Button(action: onClear) {
                    Label("Clear", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Clear log")
                .padding(10)
            }
            .onChange(of: lines.count) { _, _ in
                if let last = lines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}

struct DongleStatusView: View {
    let bridge: ZigbeeBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(bridge.statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: bridge.statusColor, radius: 3)
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
            if !bridge.lights.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bridge.lights) { light in
                        Label(light.name, systemImage: "lightbulb.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !bridge.isRunning {
                Button(action: bridge.connect) {
                    Label("Connect", systemImage: "cable.connector")
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var title: String {
        switch bridge.state {
        case .ready(let port): "Connected · \(port.replacingOccurrences(of: "/dev/cu.", with: ""))"
        default: bridge.statusTitle
        }
    }
}

/// Pick a color or a white for every bulb while music is off. Changes apply as you drag.
/// `compact` drops the system color picker, whose floating panel would close the menu bar popover.
struct ManualLightView: View {
    let controller: LightsController
    var compact = false

    private enum Mode: String, CaseIterable, Identifiable {
        case color = "Color"
        case white = "White"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .color
    @State private var color = Color.purple
    @State private var mireds = 300.0
    @State private var brightness = 0.8

    private let swatches: [(String, Color)] = [
        ("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
        ("Cyan", .cyan), ("Blue", .blue), ("Purple", .purple), ("Pink", .pink),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .color {
                HStack(spacing: 4) {
                    if !compact {
                        ColorPicker("Color", selection: $color, supportsOpacity: false)
                            .labelsHidden()
                    }
                    ForEach(swatches, id: \.0) { name, swatch in
                        Button { color = swatch } label: {
                            Circle()
                                .fill(swatch)
                                .frame(width: 20, height: 20)
                                .padding(2.5)
                                .overlay {
                                    Circle().strokeBorder(.primary.opacity(color == swatch ? 0.9 : 0), lineWidth: 1.5)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "snowflake").foregroundStyle(.cyan)
                    Slider(value: $mireds, in: 153...500)
                        .tint(.orange)
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                }
                .help("Cool daylight to warm candlelight")
            }

            HStack {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: $brightness, in: 0.02...1)
                    .tint(.white.opacity(0.8))
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
            }
        }
        .onChange(of: color) { _, _ in apply(.color) }
        .onChange(of: mireds) { _, _ in apply(.white) }
        .onChange(of: brightness) { _, _ in apply(mode) }
        .onChange(of: mode) { _, newMode in apply(newMode) }
    }

    private func apply(_ target: Mode) {
        mode = target
        switch target {
        case .color: controller.setManualColor(color, brightness: brightness)
        case .white: controller.setManualWhite(mireds: mireds, brightness: brightness)
        }
    }
}
