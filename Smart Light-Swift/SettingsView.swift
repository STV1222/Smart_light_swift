//
//  SettingsView.swift
//  Smart Light-Swift
//
//  Created by STV on 24/09/2025.
//

import SwiftUI
import AppKit
#if canImport(PythonKit)
import PythonKit
#endif

struct SettingsView: View {
    // Port and API key are sourced from the Python engine's .env; hide from UI
    private let serverPort: Int = 8008
    private let openAIKey: String = ""
    @State private var indexing = false
    @State private var foldersIndexed: [String] = []
    @State private var chunks: Int = 0
    @State private var showProgress: Bool = false
    @State private var progress: Double = 0
    @State private var progressStage: String = "Starting..."
    @State private var cancelIndexing = false
    // HTTP server disabled; keep local-only pipeline
    // Local pipeline
    @State private var engine: RagEngine? = nil
    @State private var indexer: IndexerProtocol? = nil
    
    private var progressStageText: String {
        if progress < 0.1 {
            return "Discovering files..."
        } else if progress < 0.9 {
            return "Processing files..."
        } else if progress < 0.95 {
            return "Finalizing..."
        } else if progress < 1.0 {
            return "Completing..."
        } else {
            return "Complete!"
        }
    }
    @State private var store: InMemoryVectorStore? = nil
    // Env diagnostics
    @State private var envBackend: String = ""
    @State private var envModel: String = ""
    @State private var envHFSet: Bool = false
    @State private var envOpenAISet: Bool = false
    @State private var pyEnvOK: Bool = false

    var body: some View {
        Form {
            // Server port and OpenAI key are managed via .env; no controls shown
            Section("Embedding Backend") {
                Text("Gemma (google/embeddinggemma-300m)")
                    .font(.headline)
                Text("Runs locally via Python subprocess")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("RAG Index") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                Button(indexing ? "Indexing…" : "Index folders…") { Task { await pickAndIndex() } }
                    .disabled(indexing)
                        
                        if indexing {
                            Button("Cancel") {
                                cancelIndexing = true
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                        }
                    }
                    
                    if showProgress {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: progress, total: 1.0) {
                                Text("Indexing…")
                            } currentValueLabel: {
                                Text("\(Int(progress * 100))%")
                            }
                            .progressViewStyle(.linear)
                            .animation(.easeInOut(duration: 0.3), value: progress)
                            
                            // Show progress stage
                            Text(progressStageText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .animation(.easeInOut(duration: 0.3), value: progressStageText)
                        }
                    }
                    if !foldersIndexed.isEmpty {
                        Text("Indexed folders:").font(.subheadline).bold()
                        ForEach(foldersIndexed, id: \.self) { p in
                            Text(p).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Chunks: \(chunks)").font(.caption)
                    }
                }
            }
        }
        .onAppear {
            Task { await refreshStatus() }
            // Build local components once
            if engine == nil {
                RagSession.shared.initialize(embeddingBackend: "gemma")
                self.engine = RagSession.shared.engine
                self.indexer = RagSession.shared.indexer
                self.store = RagSession.shared.store
            }
            // Read keys from .env via DotEnv
            self.envBackend = DotEnv.get("EMBEDDING_BACKEND", default: "") ?? ""
            self.envModel = DotEnv.get("LOCAL_EMBEDDING_MODEL", default: "") ?? ""
            self.envHFSet = (DotEnv.get("HF_TOKEN")?.isEmpty == false)
            self.envOpenAISet = (DotEnv.get("OPENAI_API_KEY")?.isEmpty == false)
            // Verify Python sees them
            self.pyEnvOK = SettingsView.verifyPythonEnv()
        }
        .padding(20)
        .frame(width: 480)
    }

    @MainActor
    private func pickAndIndex() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        
        indexing = true
        showProgress = true
        progress = 0
        progressStage = "Starting..."
        cancelIndexing = false
        let folders = panel.urls.map { $0.path }
        
        guard let ix = RagSession.shared.indexer else { 
            self.progress = 1.0
            indexing = false
            showProgress = false
            return 
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Hard reset behavior like Python 'replace=True'
                RagSession.shared.resetStore()
                
                // Check for cancellation before starting
                if self.cancelIndexing {
                    DispatchQueue.main.async {
                        self.handleIndexingCancellation()
                    }
                    return
                }
                
                try ix.index(folders: folders, 
                            progress: { p in
                                DispatchQueue.main.async { 
                                    print("[SettingsView] Progress callback received: \(Int(p * 100))%")
                                    self.progress = max(min(p, 1.0), 0.0)
                                    // Update stage based on progress
                                    if p < 0.1 {
                                        self.progressStage = "Discovering files..."
                                    } else if p < 0.9 {
                                        self.progressStage = "Processing files..."
                                    } else if p < 0.95 {
                                        self.progressStage = "Finalizing..."
                                    } else if p < 1.0 {
                                        self.progressStage = "Completing..."
                                    } else {
                                        self.progressStage = "Complete!"
                                    }
                                    print("[SettingsView] Progress updated to: \(Int(self.progress * 100))% - \(self.progressStage)")
                                }
                            },
                            shouldCancel: {
                                return self.cancelIndexing
                            })
                
                // Check for cancellation after indexing
                if self.cancelIndexing {
                    DispatchQueue.main.async {
                        self.handleIndexingCancellation()
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    self.progress = 1.0
                    self.foldersIndexed = folders
                    // Force a synchronous read of the store count
                    let finalChunks = RagSession.shared.store.count
                    self.chunks = finalChunks
                    print("[SettingsView] Indexing completed. Final chunk count: \(finalChunks)")
                    self.indexing = false
                    self.showProgress = false
                }
        } catch {
                DispatchQueue.main.async {
                    if let nsError = error as NSError?, nsError.code == -999 {
                        // This is a cancellation error, handle it gracefully
                        self.handleIndexingCancellation()
                    } else {
                        self.indexing = false
                        self.showProgress = false
                        NSAlert(error: NSError(domain: "Smartlight", code: 0, userInfo: [NSLocalizedDescriptionKey: "Index failed: \(error.localizedDescription)"])).runModal()
                    }
                }
            }
        }
    }
    
    @MainActor
    private func handleIndexingCancellation() {
        // Clear the store and reset all indexing state
        RagSession.shared.store.reset()
        self.foldersIndexed = []
        self.chunks = 0
        self.progress = 0
        self.indexing = false
        self.showProgress = false
        self.cancelIndexing = false
        
        // Show confirmation that indexing was cancelled
        let alert = NSAlert()
        alert.messageText = "Indexing Cancelled"
        alert.informativeText = "Indexing has been cancelled and all partially indexed data has been cleared."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private func refreshStatus() async {
        // Local-only: read from in-memory store
        chunks = self.store?.count ?? 0
    }
}
// MARK: - Private helpers
extension SettingsView {
    static func verifyPythonEnv() -> Bool {
        // Always return true since we're using LocalEmbeddingService, not PythonKit
        return true
    }
}
