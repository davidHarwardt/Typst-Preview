//
//  Typst_PreviewApp.swift
//  Typst Preview
//
//  Created by David Harwardt on 09.03.26.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var previewController: PreviewController? {
        didSet {
            previewController?.openLaunchArguments()

            if let pendingURL {
                previewController?.open(url: pendingURL)
                self.pendingURL = nil
            }
        }
    }

    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }

        if let previewController {
            previewController.open(url: url)
        } else {
            pendingURL = url
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }

        return true
    }
}

@main
struct Typst_PreviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let previewController = PreviewController()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        Window("Typst Preview", id: "main-window") {
            ContentView(controller: previewController)
                .onAppear {
                    appDelegate.previewController = previewController
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Preview…") {
                    previewController.presentOpenPanel()
                }
                .keyboardShortcut("o")
            }
        }
    }
}
