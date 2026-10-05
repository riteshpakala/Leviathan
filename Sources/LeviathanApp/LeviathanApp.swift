//
//  LeviathanApp.swift
//  LeviathanApp
//
//  WHAT: The Mac app: providers, models, prompt sets, harvests and passages, on the same core
//        as the `leviathan` command.
//  PIN:  Runs from SwiftPM with no app bundle, so it sets its own activation policy at launch;
//        without it the window would open behind others and never take keyboard focus.
//

import AppKit
import LeviathanCore
import SwiftUI

@main
enum Main {
    static func main() {
        if let request = SnapshotRequest(arguments: CommandLine.arguments) {
            MainActor.assumeIsolated { Snapshot.run(request) }
        }
        LeviathanApp.main()
    }
}

struct LeviathanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("Leviathan") {
            ContentView()
                .environment(app)
                .frame(minWidth: 1040, minHeight: 660)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Reload Workspace") { app.reload() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
