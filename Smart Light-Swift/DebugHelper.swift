import Foundation

// Debug helper to test the new optimized system
final class DebugHelper {
    
    static func testPersistentEmbeddingService() {
        print("🔍 [Debug] Testing PersistentEmbeddingService...")
        
        do {
            let service = try PersistentEmbeddingService(modelName: "google/embeddinggemma-300m")
            print("✅ [Debug] PersistentEmbeddingService initialized successfully")
            
            // Test embedding
            let testTexts = ["This is a test document", "Another test document"]
            let embeddings = try service.embed(texts: testTexts, asQuery: false)
            
            print("✅ [Debug] Generated \(embeddings.count) embeddings")
            print("✅ [Debug] Embedding dimension: \(embeddings.first?.count ?? 0)")
            
        } catch {
            print("❌ [Debug] PersistentEmbeddingService failed: \(error)")
        }
    }
    
    static func testIncrementalIndexer() {
        print("🔍 [Debug] Testing IncrementalIndexer...")
        
        do {
            let embedder = try PersistentEmbeddingService(modelName: "google/embeddinggemma-300m")
            let store = InMemoryVectorStore(dimension: embedder.dimension)
            let indexer = IncrementalIndexer(embedder: embedder, store: store)
            
            print("✅ [Debug] IncrementalIndexer initialized successfully")
            
            // Test with a small folder
            let testFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            let folders = [testFolder.path]
            
            print("🔍 [Debug] Testing indexing with folder: \(testFolder.path)")
            
            try indexer.index(folders: folders) { progress in
                print("📊 [Debug] Indexing progress: \(Int(progress * 100))%")
            }
            
            print("✅ [Debug] Indexing completed. Store has \(store.count) chunks")
            
        } catch {
            print("❌ [Debug] IncrementalIndexer failed: \(error)")
        }
    }
    
    static func testRagSession() {
        print("🔍 [Debug] Testing RagSession...")
        
        RagSession.shared.initialize(embeddingBackend: "gemma")
        print("✅ [Debug] RagSession initialized successfully")
        
        if let engine = RagSession.shared.engine {
            print("✅ [Debug] RAG Engine available")
            
            // Test a simple question
            let question = "What files do you have access to?"
            print("🔍 [Debug] Testing question: \(question)")
            
            Task {
                do {
                    let answer = try await engine.answer(question: question)
                    print("✅ [Debug] RAG Engine answer: \(answer)")
                } catch {
                    print("❌ [Debug] RAG Engine failed: \(error)")
                }
            }
        } else {
            print("❌ [Debug] RAG Engine not available")
        }
    }
    
    static func runAllTests() {
        print("🚀 [Debug] Starting comprehensive system test...")
        print("=" * 50)
        
        testPersistentEmbeddingService()
        print("-" * 30)
        
        testIncrementalIndexer()
        print("-" * 30)
        
        testRagSession()
        print("-" * 30)
        
        print("🏁 [Debug] All tests completed!")
    }
}

// String extension for easy repetition
extension String {
    static func * (left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}
