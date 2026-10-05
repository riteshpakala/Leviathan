//
//  Snapshot.swift
//  LeviathanApp
//
//  WHAT: Renders one screen to a PNG and exits, for the README's pictures:
//          LeviathanApp --snapshot <screen> --out <file.png> [--dark]
//        with LEVIATHAN_ROOT naming the workspace to show (scripts/screenshots.sh builds a demo one).
//  PIN:  The window is never shown: it is drawn off screen, at no Dock icon, and copied out of
//        its own views, so it needs no screen-recording permission and leaves the screen alone.
//        Nothing is saved to the app's settings.
//

import AppKit
import LeviathanCore
import SwiftUI

struct SnapshotRequest: Sendable {
    var screen: String
    var out: URL
    var dark: Bool
    /// The area a passage screen opens with selected.
    var area: Int?

    init?(arguments: [String]) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        guard let screen = value("--snapshot"), let out = value("--out") else { return nil }
        self.screen = screen
        self.out = URL(fileURLWithPath: out)
        dark = arguments.contains("--dark")
        area = value("--area").flatMap(Int.init)
    }
}

@MainActor
enum Snapshot {
    /// Set only in snapshot mode.
    static var request: SnapshotRequest?

    static let screens = ["connect-host", "connect-key", "model-picker", "my-work", "revise-passage", "cost-guard"]

    static func run(_ request: SnapshotRequest) -> Never {
        self.request = request
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let model = AppModel()
        guard let (view, size) = scene(request.screen, app: model) else {
            FileHandle.standardError.write(Data("no screen '\(request.screen)'; screens: \(screens.joined(separator: ", "))\n".utf8))
            exit(64)
        }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: request.dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        // A window's own background, which the copy below does not draw on its own.
        let host = NSHostingView(rootView: view.environment(model).frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderBack(nil)
        // Let appearance, tasks and checks settle, laying out again as they land: an off-screen
        // window gets no display cycles of its own.
        for step in 1...12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(step)) {
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            host.layoutSubtreeIfNeeded()
            // Twice the points, so the picture is sharp on a Retina display.
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0) else { exit(70) }
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(70) }
            do {
                try FileManager.default.createDirectory(at: request.out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: request.out)
            } catch {
                FileHandle.standardError.write(Data("could not write \(request.out.path): \(error)\n".utf8))
                exit(73)
            }
            exit(0)
        }
        application.run()
        exit(0)
    }

    /// The view for a screen, with the state it shows, and the size to draw it at.
    static func scene(_ screen: String, app: AppModel) -> (AnyView, CGSize)? {
        let work = app.works.first
        switch screen {
        case "connect-host":
            return (AnyView(ConnectView(flow: ConnectFlow())), CGSize(width: 760, height: 580))
        case "connect-key":
            let flow = ConnectFlow()
            if let preset = ProviderPresets.preset("openrouter") { flow.choose(preset, app: app) }
            flow.runCheck()
            return (AnyView(ConnectView(flow: flow)), CGSize(width: 760, height: 580))
        case "model-picker":
            let flow = ConnectFlow()
            if let preset = ProviderPresets.preset("openrouter") { flow.choose(preset, app: app) }
            flow.runCheck()
            flow.step = .models
            flow.openWeightsOnly = true
            flow.chosen = ["meta-llama/llama-3.3-70b-instruct"]
            return (AnyView(ConnectView(flow: flow)), CGSize(width: 760, height: 580))
        case "my-work":
            guard let work else { return nil }
            app.selection = .work(work.id)
            return (AnyView(ContentView()), CGSize(width: 1180, height: 860))
        case "revise-passage":
            guard let work, let thread = app.workThreads[work.id]?.first(where: { $0.set == StudyKind.revise.rawValue }) else { return nil }
            if request?.area == nil { request?.area = 1 }
            app.selection = .workThread(work.id, thread.ref, thread.set)
            return (AnyView(ContentView()), CGSize(width: 1280, height: 760))
        case "cost-guard":
            guard let target = app.models.first(where: { $0.pricing != nil && app.sampleCount($0.ref, app.sets.first?.id ?? "") == 0 }),
                  let set = app.sets.first else { return nil }
            app.selection = .thread(target.ref, set.id)
            return (AnyView(ContentView()), CGSize(width: 1180, height: 700))
        default:
            return nil
        }
    }
}
