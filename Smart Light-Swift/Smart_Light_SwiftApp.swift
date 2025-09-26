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
                    
                    // Debug: Test the new optimized system (disabled for now)
                    #if DEBUG && false
                    Task {
                        print("🔍 [Debug] Testing optimized system on app startup...")
                        DebugHelper.testPersistentEmbeddingService()
                    }
                    #endif
                }
                .onDisappear { server.stop() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        Settings { SettingsView() }   // Cmd+, opens this
    }
}
