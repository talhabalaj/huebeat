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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
                .frame(minWidth: 920, minHeight: 680)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 740)
    }
}
