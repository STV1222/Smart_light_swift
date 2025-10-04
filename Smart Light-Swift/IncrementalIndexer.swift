import Foundation
import Dispatch

// Python-based indexer that uses the working Python project logic
final class IncrementalIndexer {
    private let pythonIndexer: PythonIndexerService
    private let store: InMemoryVectorStore
    private(set) var indexedFolders: [String] = []
    
    init(embedder: EmbeddingService, store: InMemoryVectorStore) {
        // We don't need the embedder anymore since Python handles everything
        self.pythonIndexer = PythonIndexerService()
        self.store = store
        
        // Start the Python process
        do {
            try pythonIndexer.startProcess()
                } catch {
            print("[IncrementalIndexer] Failed to start Python indexer: \(error)")
        }
    }
    
    func index(folders: [String], progress: ((Double) -> Void)? = nil, shouldCancel: (() -> Bool)? = nil) throws {
        print("[IncrementalIndexer] PYTHON-BASED INDEXING: Processing \(folders.count) folders")
        
        // Check for cancellation before starting
        if shouldCancel?() == true {
            print("[IncrementalIndexer] Indexing cancelled before starting")
            try handleCancellation()
            throw NSError(domain: "IncrementalIndexer", code: -999, userInfo: [NSLocalizedDescriptionKey: "Indexing cancelled by user"])
        }
        
        // Update indexed folders
        indexedFolders = folders
        
        // Use Python indexer to process folders with retry logic
        var lastError: Error?
        let maxRetries = 2
        
        for attempt in 1...maxRetries {
            do {
                // Check for cancellation before each attempt
                if shouldCancel?() == true {
                    print("[IncrementalIndexer] Indexing cancelled before attempt \(attempt)")
                    try handleCancellation()
                    throw NSError(domain: "IncrementalIndexer", code: -999, userInfo: [NSLocalizedDescriptionKey: "Indexing cancelled by user"])
                }
                
                let result = try pythonIndexer.indexFolders(folders, excludes: [
                    "node_modules", "__pycache__", ".git", ".DS_Store",
                    "~$*", "*.tmp", "*.temp", "*.lock", "*.swp", "*.swo"
                ], replace: false) { progressValue, currentPath in
                    // Check for cancellation during progress updates
                    if shouldCancel?() == true {
                        print("[IncrementalIndexer] Indexing cancelled during progress update")
                        return
                    }
                    // Convert Python progress to Swift progress
                    progress?(progressValue)
                    print("[IncrementalIndexer] Python progress: \(Int(progressValue * 100))% - \(currentPath)")
                }
                
                // Check for cancellation after indexing completes
                if shouldCancel?() == true {
                    print("[IncrementalIndexer] Indexing cancelled after completion, cleaning up...")
                    try handleCancellation()
                    throw NSError(domain: "IncrementalIndexer", code: -999, userInfo: [NSLocalizedDescriptionKey: "Indexing cancelled by user"])
                }
                
                print("[IncrementalIndexer] ✅ Python indexing completed:")
                print("[IncrementalIndexer] - Added: \(result["added"] ?? 0) chunks")
                print("[IncrementalIndexer] - Deleted: \(result["deleted"] ?? 0) chunks")
                print("[IncrementalIndexer] - Total size: \(result["size"] ?? 0) chunks")
                
                // Load the indexed data from Python into Swift store
                print("[IncrementalIndexer] 🔄 Starting data synchronization from Python to Swift...")
                try loadDataFromPythonIndexer()
                print("[IncrementalIndexer] ✅ Data synchronization completed")
                
                // Final progress update
                progress?(1.0)
            return
                
            } catch {
                lastError = error
                
                // Check if this is a cancellation error
                if let nsError = error as NSError?, nsError.code == -999 {
                    print("[IncrementalIndexer] 🛑 Indexing cancelled by user")
                    // Don't retry on cancellation
                    throw error
                }
                
                print("[IncrementalIndexer] ❌ Python indexing failed (attempt \(attempt)/\(maxRetries)): \(error)")
                
                if attempt < maxRetries {
                    print("[IncrementalIndexer] Retrying in 2 seconds...")
                    Thread.sleep(forTimeInterval: 2.0)
                    
                    // Try to restart the Python process
                    do {
                        try pythonIndexer.startProcess()
                        print("[IncrementalIndexer] Python process restarted")
            } catch {
                        print("[IncrementalIndexer] Failed to restart Python process: \(error)")
                    }
                }
            }
        }
        
        // If all retries failed, throw the last error
        print("[IncrementalIndexer] ❌ All retry attempts failed")
        throw lastError ?? NSError(domain: "IncrementalIndexer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Python indexing failed after all retries"])
    }
    
    func getStatus() -> [String: Any] {
        do {
            return try pythonIndexer.getStatus()
            } catch {
            print("[IncrementalIndexer] Failed to get status: \(error)")
            return [
                "folders": indexedFolders,
                "chunks": 0,
                "last_update": NSNull()
            ]
        }
    }
    
    func reset() {
        print("[IncrementalIndexer] Resetting Python indexer...")
        // The Python indexer will handle resetting when we call index with replace=true
    }
    
    func clearIndex() throws {
        print("[IncrementalIndexer] Clearing all indexed data...")
        
        // Clear the Swift store
        store.reset()
        
        // Ensure Python process is running before attempting to clear
        if !pythonIndexer.isProcessRunning {
            print("[IncrementalIndexer] Python process not running, starting it...")
            do {
                try pythonIndexer.startProcess()
                print("[IncrementalIndexer] ✅ Python process started for clearing")
            } catch {
                print("[IncrementalIndexer] ❌ Failed to start Python process: \(error)")
                // Continue with clearing anyway - we can still clear the Swift store
            }
        }
        
        // Clear the Python indexer data using the dedicated clear action
        do {
            let result = try pythonIndexer.clearIndex()
            print("[IncrementalIndexer] ✅ Cleared Python indexer data")
            if let message = result["message"] as? String {
                print("[IncrementalIndexer] - \(message)")
            }
            if let clearedFiles = result["cleared_files"] as? [String] {
                print("[IncrementalIndexer] - Cleared files: \(clearedFiles)")
            }
            
            // Restart the Python process to clear any in-memory data
            print("[IncrementalIndexer] 🔄 Restarting Python process to clear memory...")
            pythonIndexer.stopProcess()
            try pythonIndexer.startProcess()
            print("[IncrementalIndexer] ✅ Python process restarted with clean memory")
            
        } catch {
            print("[IncrementalIndexer] ❌ Failed to clear Python indexer data: \(error)")
            // Fallback: Clear Python index files directly from Swift
            print("[IncrementalIndexer] 🔄 Attempting to clear Python files directly...")
            clearPythonIndexFilesDirectly()
        }
        
        // Reset indexed folders
        indexedFolders = []
        
        print("[IncrementalIndexer] ✅ All indexed data cleared")
    }
    
    private func clearPythonIndexFilesDirectly() {
        let ragHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".smartlight/rag_db")
        let indexFiles = [
            ragHome.appendingPathComponent("faiss.index"),
            ragHome.appendingPathComponent("meta.jsonl"),
            ragHome.appendingPathComponent("manifest.json")
        ]
        
        var clearedCount = 0
        for fileURL in indexFiles {
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                    clearedCount += 1
                    print("[IncrementalIndexer] ✅ Removed: \(fileURL.lastPathComponent)")
                }
            } catch {
                print("[IncrementalIndexer] ⚠️ Could not remove \(fileURL.lastPathComponent): \(error)")
            }
        }
        
        print("[IncrementalIndexer] ✅ Directly cleared \(clearedCount) Python index files")
    }
    
    func loadDataFromPythonIndexer() throws {
        print("[IncrementalIndexer] Loading data from Python indexer into Swift store...")
        
        // Get embeddings data from Python indexer
        let embeddingsData: [String: Any]
        do {
            embeddingsData = try pythonIndexer.getEmbeddings()
            print("[IncrementalIndexer] ✅ Successfully retrieved embeddings data from Python")
        } catch {
            print("[IncrementalIndexer] ❌ Failed to get embeddings from Python: \(error)")
            throw error
        }
        
        guard let embeddings = embeddingsData["embeddings"] as? [[String: Any]],
              let dimension = embeddingsData["dimension"] as? Int else {
            print("[IncrementalIndexer] ❌ Invalid embeddings data format")
            print("[IncrementalIndexer] Data keys: \(embeddingsData.keys)")
            return
        }
        
        print("[IncrementalIndexer] Found \(embeddings.count) embeddings with dimension \(dimension)")
        
        // Clear existing data
        store.reset()
        
        var loadedCount = 0
        for embeddingData in embeddings {
            guard let text = embeddingData["text"] as? String,
                  let path = embeddingData["path"] as? String,
                  let embeddingArray = embeddingData["embedding"] as? [Double] else {
                continue
            }
            
            // Convert Double array to Float array
            let embedding = embeddingArray.map { Float($0) }
            
            // Add page info to path if available
            var fullPath = path
            if let page = embeddingData["page"] as? Int {
                fullPath = "\(path)#p\(page)"
            }
            
            store.add(path: fullPath, text: text, embedding: embedding)
            loadedCount += 1
        }
        
        print("[IncrementalIndexer] ✅ Loaded \(loadedCount) chunks from Python indexer into Swift store")
        print("[IncrementalIndexer] Swift store now has \(store.count) chunks")
    }
    
    /// Handle cancellation by cleaning up all indexed data
    private func handleCancellation() throws {
        print("[IncrementalIndexer] 🛑 Handling indexing cancellation...")
        
        // Stop the Python process immediately
        pythonIndexer.stopProcess()
        print("[IncrementalIndexer] ✅ Python process stopped")
        
        // Clear all indexed data from Python indexer
        do {
            try clearIndex()
            print("[IncrementalIndexer] ✅ Cleared all indexed data")
        } catch {
            print("[IncrementalIndexer] ⚠️ Failed to clear indexed data: \(error)")
            // Continue with Swift store cleanup even if Python cleanup fails
        }
        
        // Clear Swift store
        store.reset()
        print("[IncrementalIndexer] ✅ Cleared Swift store")
        
        // Reset indexed folders
        indexedFolders = []
        print("[IncrementalIndexer] ✅ Reset indexed folders")
        
        print("[IncrementalIndexer] 🛑 Cancellation cleanup completed")
    }
    
    deinit {
        pythonIndexer.stopProcess()
    }
}
