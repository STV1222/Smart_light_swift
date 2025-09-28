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
    
    func getStoreCount() -> Int {
        return store.count
    }
}


