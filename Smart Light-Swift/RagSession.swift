import Foundation

final class RagSession {
    static let shared = RagSession()

    private init() {}

    private(set) var embedder: EmbeddingService?
    private(set) var store: InMemoryVectorStore = InMemoryVectorStore(dimension: 768)
    private(set) var indexer: IndexerProtocol?
    private(set) var engine: RagEngine?

    func initialize(embeddingBackend: String) {
        // Only initialize once to preserve data across reinitializations
        guard embedder == nil else {
            print("[RagSession] Already initialized, skipping")
            return
        }
        
        do {
            // Use persistent embedding service for much better performance
            print("[RagSession] Attempting to initialize persistent embedding service...")
            let persistent = try PersistentEmbeddingService(modelName: "google/embeddinggemma-300m")
            print("[RagSession] ✅ Successfully initialized persistent embedding service for google/embeddinggemma-300m")
            self.embedder = persistent
            // Create store with proper dimension
            self.store = InMemoryVectorStore(dimension: persistent.dimension)
            print("[RagSession] Created store object: \(ObjectIdentifier(store))")
            // Use incremental indexer for much faster processing
            self.indexer = IncrementalIndexer(embedder: persistent, store: self.store)
            self.engine = RagEngine(embedder: persistent, store: self.store)
            print("[RagSession] ✅ Using PersistentEmbeddingService - optimized for large files")
            
            // Try to load existing indexed data
            loadExistingData()
        } catch {
            print("[RagSession] ❌ Failed to initialize persistent embedding service: \(error)")
            print("[RagSession] 🔄 Falling back to local embedding service...")
            // Fallback to local service if persistent fails
            do {
                let local = try LocalEmbeddingService(modelName: "google/embeddinggemma-300m")
                print("[RagSession] ✅ Successfully initialized local embedding service")
                self.embedder = local
                self.store = InMemoryVectorStore(dimension: local.dimension)
                self.indexer = Indexer(embedder: local, store: self.store)
                self.engine = RagEngine(embedder: local, store: self.store)
                print("[RagSession] ⚠️ Using LocalEmbeddingService - may be slower for large files")
            } catch {
                print("[RagSession] ❌ Failed to initialize local embedding service: \(error)")
                fatalError("Failed to initialize Gemma embeddings: \(error.localizedDescription)")
            }
        }
    }
    
    func resetStore() {
        print("[RagSession] Resetting store for fresh indexing")
        store.reset()
    }
    
    func clearIndex() throws {
        print("[RagSession] Clearing all indexed data...")
        
        // Clear the Swift store
        store.reset()
        
        // Clear the Python indexer data if using IncrementalIndexer
        if let indexer = indexer as? IncrementalIndexer {
            try indexer.clearIndex()
        }
        
        print("[RagSession] ✅ All indexed data cleared")
    }
    
    func getStoreCount() -> Int {
        return store.count
    }
    
    private func loadExistingData() {
        guard let indexer = indexer as? IncrementalIndexer else {
            print("[RagSession] Not using IncrementalIndexer, skipping data load")
            return
        }
        
        print("[RagSession] Attempting to load existing indexed data...")
        do {
            try indexer.loadDataFromPythonIndexer()
            print("[RagSession] ✅ Successfully loaded existing data: \(store.count) chunks")
        } catch {
            print("[RagSession] ⚠️ Could not load existing data: \(error)")
            print("[RagSession] This is normal if no data has been indexed yet")
        }
    }
}


