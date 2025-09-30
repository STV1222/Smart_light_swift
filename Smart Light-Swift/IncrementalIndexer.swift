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
        
        // Update indexed folders
        indexedFolders = folders
        
        // Use Python indexer to process folders with retry logic
        var lastError: Error?
        let maxRetries = 2
        
        for attempt in 1...maxRetries {
            do {
                let result = try pythonIndexer.indexFolders(folders, excludes: ["node_modules", "__pycache__", ".git", ".DS_Store"], replace: false) { progressValue, currentPath in
                    // Convert Python progress to Swift progress
                    progress?(progressValue)
                    print("[IncrementalIndexer] Python progress: \(Int(progressValue * 100))% - \(currentPath)")
                }
                
                print("[IncrementalIndexer] ✅ Python indexing completed:")
                print("[IncrementalIndexer] - Added: \(result["added"] ?? 0) chunks")
                print("[IncrementalIndexer] - Deleted: \(result["deleted"] ?? 0) chunks")
                print("[IncrementalIndexer] - Total size: \(result["size"] ?? 0) chunks")
                
                // Final progress update
                progress?(1.0)
            return
                
            } catch {
                lastError = error
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
    
    deinit {
        pythonIndexer.stopProcess()
    }
}
