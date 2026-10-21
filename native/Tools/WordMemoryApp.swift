import AppKit
import SwiftUI

@MainActor
private final class WordMemoryAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
@MainActor
private struct WordMemoryApp: App {
    @NSApplicationDelegateAdaptor(WordMemoryAppDelegate.self) private var delegate
    @StateObject private var model = MacWordMemoryModel()

    var body: some Scene {
        Window("她说词库", id: "main") {
            MacWordMemoryView(model: model, onDone: { NSApplication.shared.keyWindow?.close() })
        }.defaultSize(width: 720, height: 780)
    }
}
