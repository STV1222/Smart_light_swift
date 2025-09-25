import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

final class Indexer {
    private let embedder: EmbeddingService
    private let store: InMemoryVectorStore
    private(set) var indexedFolders: [String] = []

    init(embedder: EmbeddingService, store: InMemoryVectorStore) {
        self.embedder = embedder
        self.store = store
    }

    func index(folders: [String], progress: ((Double) -> Void)? = nil, shouldCancel: (() -> Bool)? = nil) throws {
        self.indexedFolders = folders
        let fm = FileManager.default
        var files: [String] = []
        
        // Supported file extensions like Python version
        let supportedExts: Set<String> = [
            ".pdf", ".docx", ".pptx", ".rtf", ".txt", ".md", ".markdown", ".html", ".htm",
            ".csv", ".tsv", ".log", ".tex", ".json", ".yaml", ".yml", ".toml", ".ini",
            ".xlsx", ".xlsm", ".xls",
            ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".go", ".rb", ".rs",
            ".cpp", ".cc", ".c", ".h", ".hpp", ".cs", ".php", ".sh", ".sql"
        ]
        
        for folder in folders {
            let en = fm.enumerator(atPath: folder)
            while let rel = (en?.nextObject() as? String) {
                let path = (folder as NSString).appendingPathComponent(rel)
                let ext = (rel as NSString).pathExtension.lowercased()
                if supportedExts.contains(".\(ext)") {
                    files.append(path)
                }
            }
        }
        
        let total = max(1, files.count)
        var done = 0
        print("[Indexer] Starting to process \(files.count) files")
        for f in files {
            // Check for cancellation before processing each file
            if let shouldCancel = shouldCancel, shouldCancel() {
                print("[Indexer] Indexing cancelled by user")
                throw NSError(domain: "Indexer", code: -999, userInfo: [NSLocalizedDescriptionKey: "Indexing cancelled by user"])
            }
            
            do {
                print("[Indexer] Processing file \(done + 1)/\(total): \(f)")
                let text = try extractText(path: f)
                let chunks = chunk(text: text, path: f)
                print("[Indexer] Extracted \(chunks.count) chunks from \(f)")
                
                // Check for cancellation before embedding
                if let shouldCancel = shouldCancel, shouldCancel() {
                    print("[Indexer] Indexing cancelled by user before embedding")
                    throw NSError(domain: "Indexer", code: -999, userInfo: [NSLocalizedDescriptionKey: "Indexing cancelled by user"])
                }
                
                let embs = try embedder.embed(texts: chunks, asQuery: false)
                print("[Indexer] Generated \(embs.count) embeddings for \(f)")
                for (i, e) in embs.enumerated() { 
                    let chunkPath = f + "#p\(i)"
                    store.add(path: chunkPath, text: chunks[i], embedding: e) 
                    print("[Indexer] Added chunk \(i): \(chunkPath) - \(String(chunks[i].prefix(50)))...")
                }
                print("[Indexer] Added \(chunks.count) chunks to store. Total store count: \(store.count)")
            } catch {
                print("[Indexer] Failed to process file \(f): \(error)")
                if let nsError = error as NSError?, nsError.code == -7 {
                    print("[Indexer] Embedding timeout for file \(f), skipping...")
                } else if let nsError = error as NSError?, nsError.code == -6 {
                    print("[Indexer] Embedding timeout for file \(f), skipping...")
                } else if let nsError = error as NSError?, nsError.code == -999 {
                    // Re-throw cancellation errors
                    throw error
                }
                // Continue with other files for other errors
            }
            done += 1
            progress?(Double(done)/Double(total))
        }
        print("[Indexer] Completed processing. Total chunks in store: \(store.count)")
    }

    private func extractText(path: String) throws -> String {
        if path.hasSuffix(".txt") || path.hasSuffix(".md") {
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        if path.hasSuffix(".pdf") {
            #if canImport(PDFKit)
            if let pdf = PDFDocument(url: URL(fileURLWithPath: path)) {
                var out = ""
                for i in 0..<pdf.pageCount { out += pdf.page(at: i)?.string ?? ""; out += "\n" }
                if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return out }
            }
            #endif
        }
        // Fallback to filename as content when rich extractors are not available
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func chunk(text: String, path: String) -> [String] {
        // More sophisticated chunking like Python version
        let lines = text.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentChunk = ""
        var currentLength = 0
        let maxChunkLength = 2000 // Reasonable chunk size
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else {
                // Empty line - end current chunk if it has content
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                    currentChunk = ""
                    currentLength = 0
                }
                continue
            }
            
            // Check if adding this line would exceed max length
            if currentLength + trimmedLine.count > maxChunkLength && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                currentChunk = trimmedLine
                currentLength = trimmedLine.count
            } else {
                if !currentChunk.isEmpty {
                    currentChunk += "\n" + trimmedLine
                } else {
                    currentChunk = trimmedLine
                }
                currentLength = currentChunk.count
            }
        }
        
        // Add final chunk if it has content
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        // Limit number of chunks per file (like Python version)
        return Array(chunks.prefix(200))
    }
}


