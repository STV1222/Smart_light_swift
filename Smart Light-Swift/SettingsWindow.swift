//
//  SettingsWindow.swift
//  Smart Light-Swift
//
//  Created by STV on 24/09/2025.
//

import SwiftUI
#if canImport(AppKit)
import AppKit

enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 420, height: 320))
        win.center()
        win.isReleasedWhenClosed = false
        win.standardWindowButton(.zoomButton)?.isHidden = true

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { _ in
            self.window = nil
        }

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif


