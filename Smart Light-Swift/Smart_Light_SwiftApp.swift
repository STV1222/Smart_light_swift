//
//  Smart_Light_SwiftApp.swift
//  Smart Light-Swift
//
//  Created by STV on 24/09/2025.
//

import SwiftUI

@main
struct Smart_Light_SwiftApp: App {
    @StateObject private var server = PythonServer()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .onAppear {
                    EnvDiagnostics.verifyAndLog()
                    // Local mode: no server startup
                }
                .onDisappear { server.stop() }
        }
        Settings { SettingsView() }   // Cmd+, opens this
    }
}
