import Foundation

final class RagSession {
    static let shared = RagSession()

    private init() {}

    private(set) var embedder: EmbeddingService?
    private(set) var store: InMemoryVectorStore = InMemoryVectorStore(dimension: 768)
    private(set) var indexer: Indexer?
    private(set) var engine: RagEngine?

    func initialize(embeddingBackend: String) {
        // Only initialize once to preserve data
        guard embedder == nil else {
            print("[RagSession] Already initialized, skipping")
            return
        }
        
        do {
            let local = try LocalEmbeddingService(modelName: "google/embeddinggemma-300m")
            print("[RagSession] Successfully initialized local embedding service for google/embeddinggemma-300m")
            self.embedder = local
            // Create store with proper dimension
            self.store = InMemoryVectorStore(dimension: local.dimension)
            self.indexer = Indexer(embedder: local, store: self.store)
            self.engine = RagEngine(embedder: local, store: self.store)
        } catch {
            print("[RagSession] Failed to initialize local embedding service: \(error)")
            fatalError("Failed to initialize Gemma embeddings: \(error.localizedDescription)")
        }
    }
}


