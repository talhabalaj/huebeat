import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = LightsController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `open -a Huebeat --args -HuebeatAutostart YES` starts listening as soon as the dongle is ready (for testing).
        if UserDefaults.standard.bool(forKey: "HuebeatAutostart") {
            controller.bridge.onReady = { [controller] in controller.start(config: AppConfig()) }
        }
        controller.bridge.connect()
    }

    // Closing the window keeps the lights running; quit from the menu bar item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Restore the bulbs and free the serial port before exiting, so no helper is left holding the dongle.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isRunning || controller.bridge.isRunning else { return .terminateNow }
        Task {
            await controller.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct HuebeatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Huebeat", id: "main") {
            ContentView(controller: appDelegate.controller)
                .frame(minWidth: 880, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 720)

        MenuBarExtra("Huebeat", systemImage: appDelegate.controller.isRunning ? "lightbulb.max.fill" : "lightbulb") {
            MenuBarPanel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact: power, preset and quick light control. Tuning and the log live in the window.
private struct MenuBarPanel: View {
    @Bindable var controller: LightsController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = controller.lastError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.needsAudioPermission {
                        Button("Open Privacy Settings", action: controller.openAudioPrivacySettings)
                            .controlSize(.small)
                    }
                }
            }

            Picker("Mode", selection: $controller.config.preset) {
                ForEach(MusicPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.isRunning)

            ManualLightView(controller: controller, compact: true)
                .disabled(controller.isRunning || !controller.bridge.isReady)
                .opacity(controller.isRunning ? 0.4 : 1)

            Divider()

            footer
        }
        .padding(16)
        .frame(width: 290)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(controller.currentColor.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(Brand.gradient))
                .frame(width: 30, height: 30)
                .shadow(color: controller.currentColor?.color ?? Brand.pink.opacity(0.5), radius: controller.isRunning ? 8 : 3)
                .opacity(controller.isRunning ? 1 : 0.6)
                .animation(.easeOut(duration: 0.25), value: controller.currentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("Huebeat").font(.headline)
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: controller.toggleRun) {
                Image(systemName: controller.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(controller.isRunning ? .secondary : Brand.pink)
            .disabled(controller.isTransitioning)
            .help(controller.isRunning ? "Stop" : "Start")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(controller.bridge.statusColor).frame(width: 7, height: 7)
            Text(controller.bridge.statusTitle)
            if controller.config.dryRun {
                Text("· Dry run")
            }
            if !controller.bridge.isRunning {
                Button("Connect", action: controller.bridge.connect)
                    .buttonStyle(.link)
            }
            Spacer()
            Button {
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Image(systemName: "macwindow")
            }
            .help("Open Huebeat")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Huebeat")
            .keyboardShortcut("q")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }
}
