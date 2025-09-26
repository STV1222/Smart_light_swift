import Foundation
import Dispatch
#if canImport(PDFKit)
import PDFKit
#endif

final class ParallelIndexer {
    private let embedder: EmbeddingService
    private let store: InMemoryVectorStore
    private(set) var indexedFolders: [String] = []
    
    // Parallel processing configuration
    private let maxConcurrentFiles = ProcessInfo.processInfo.processorCount // Use all CPU cores
    private let fileProcessingQueue = DispatchQueue(label: "file.processing", qos: .userInitiated, attributes: .concurrent)
    private let embeddingQueue = DispatchQueue(label: "embedding.processing", qos: .userInitiated, attributes: .concurrent)
    private let storeQueue = DispatchQueue(label: "store.access", qos: .userInitiated)
    
    // Batch processing
    private let maxBatchSize = 50 // Process up to 50 files in one embedding batch
    private var fileBatches: [[String]] = []
    
    init(embedder: EmbeddingService, store: InMemoryVectorStore) {
        self.embedder = embedder
        self.store = store
    }
    
    func index(folders: [String], progress: ((Double) -> Void)? = nil, shouldCancel: (() -> Bool)? = nil) throws {
        self.indexedFolders = folders
        let fm = FileManager.default
        var files: [String] = []
        
        // Supported file extensions
        let supportedExts: Set<String> = [
            ".pdf", ".docx", ".pptx", ".rtf", ".txt", ".md", ".markdown", ".html", ".htm",
            ".csv", ".tsv", ".log", ".tex", ".json", ".yaml", ".yml", ".toml", ".ini",
            ".xlsx", ".xlsm", ".xls",
            ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".go", ".rb", ".rs",
            ".cpp", ".cc", ".c", ".h", ".hpp", ".cs", ".php", ".sh", ".sql"
        ]
        
        // Collect all files
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
        
        print("[ParallelIndexer] Found \(files.count) files to process with \(maxConcurrentFiles) concurrent workers")
        
        // Create batches for parallel processing
        fileBatches = files.chunked(into: maxBatchSize)
        let totalBatches = fileBatches.count
        
        // Process batches in parallel
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: maxConcurrentFiles)
        var processedBatches = 0
        let progressLock = NSLock()
        
        for (batchIndex, batch) in fileBatches.enumerated() {
            // Check for cancellation before starting each batch
            if let shouldCancel = shouldCancel, shouldCancel() {
                print("[ParallelIndexer] Indexing cancelled by user")
                throw NSError(domain: "Indexer", code: -999, userInfo: [NSLocalizedDescriptionKey: "Indexing cancelled by user"])
            }
            
            semaphore.wait()
            group.enter()
            
            fileProcessingQueue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                
                do {
                    try self.processBatch(batch, batchIndex: batchIndex, totalBatches: totalBatches)
                    
                    progressLock.lock()
                    processedBatches += 1
                    let progressValue = Double(processedBatches) / Double(totalBatches)
                    progress?(progressValue)
                    progressLock.unlock()
                    
                } catch {
                    print("[ParallelIndexer] Batch \(batchIndex) failed: \(error)")
                    // Continue with other batches
                }
            }
        }
        
        // Wait for all batches to complete
        group.wait()
        
        print("[ParallelIndexer] Completed processing. Total chunks in store: \(store.count)")
    }
    
    private func processBatch(_ files: [String], batchIndex: Int, totalBatches: Int) throws {
        print("[ParallelIndexer] Processing batch \(batchIndex + 1)/\(totalBatches) with \(files.count) files")
        
        // Extract text from all files in parallel
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: maxConcurrentFiles)
        var fileContents: [(path: String, chunks: [String])] = []
        let contentsLock = NSLock()
        
        for file in files {
            semaphore.wait()
            group.enter()
            
            fileProcessingQueue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                
                do {
                    let text = try self.extractText(path: file)
                    let chunks = self.chunk(text: text, path: file)
                    
                    contentsLock.lock()
                    fileContents.append((path: file, chunks: chunks))
                    contentsLock.unlock()
                    
                } catch {
                    print("[ParallelIndexer] Failed to extract text from \(file): \(error)")
                }
            }
        }
        
        group.wait()
        
        // Combine all chunks for batch embedding
        var allChunks: [String] = []
        var chunkPaths: [String] = []
        
        for fileContent in fileContents {
            for (i, chunk) in fileContent.chunks.enumerated() {
                allChunks.append(chunk)
                chunkPaths.append(fileContent.path + "#p\(i)")
            }
        }
        
        if allChunks.isEmpty {
            print("[ParallelIndexer] No chunks to embed in batch \(batchIndex)")
            return
        }
        
        print("[ParallelIndexer] Embedding \(allChunks.count) chunks from batch \(batchIndex)")
        
        // Embed all chunks in one batch
        let embeddings = try embedder.embed(texts: allChunks, asQuery: false, progress: nil)
        
        // Add to store synchronously to ensure it's completed before returning
        storeQueue.sync {
            for (i, embedding) in embeddings.enumerated() {
                let chunkPath = chunkPaths[i]
                let chunkText = allChunks[i]
                self.store.add(path: chunkPath, text: chunkText, embedding: embedding)
            }
            print("[ParallelIndexer] Added \(embeddings.count) chunks to store from batch \(batchIndex)")
        }
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
        // Advanced semantic chunking strategy for maximum quality
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        
        // Different chunking strategies based on file type
        switch fileExtension {
        case "pdf", "docx", "pptx":
            return chunkDocument(text: text, fileName: fileName)
        case "py", "js", "ts", "java", "cpp", "c", "h", "swift":
            return chunkCode(text: text, fileName: fileName)
        case "md", "txt", "rtf":
            return chunkText(text: text, fileName: fileName)
        default:
            return chunkGeneric(text: text, fileName: fileName)
        }
    }
    
    private func chunkDocument(text: String, fileName: String) -> [String] {
        // Document-specific chunking with paragraph awareness - more inclusive
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var currentChunk = ""
        let maxChunkLength = 1000 // Reduced from 2000 to 1000 for more chunks
        let minChunkLength = 30 // Even lower minimum to capture more content
        
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            if currentChunk.count + trimmed.count > maxChunkLength && !currentChunk.isEmpty {
                // Always add chunk if it has any content, regardless of size
                chunks.append(buildChunk(content: currentChunk, fileName: fileName, type: "document"))
                currentChunk = trimmed
            } else {
                if !currentChunk.isEmpty {
                    currentChunk += "\n\n" + trimmed
                } else {
                    currentChunk = trimmed
                }
            }
        }
        
        // Always add final chunk if it has content
        if !currentChunk.isEmpty {
            chunks.append(buildChunk(content: currentChunk, fileName: fileName, type: "document"))
        }
        
        // If no paragraphs found, fall back to line-based chunking
        if chunks.isEmpty {
            return chunkGeneric(text: text, fileName: fileName)
        }
        
        return Array(chunks.prefix(1000)) // Increased from 500 to 1000
    }
    
    private func chunkCode(text: String, fileName: String) -> [String] {
        // Code-specific chunking with function/class awareness - more inclusive
        let lines = text.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentChunk = ""
        var currentLength = 0
        let maxChunkLength = 900 // Reduced from 1800 to 900 for more chunks
        let minChunkLength = 30 // Even lower minimum
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check for function/class boundaries
            let isFunctionStart = trimmed.hasPrefix("def ") || trimmed.hasPrefix("function ") || 
                                trimmed.hasPrefix("class ") || trimmed.hasPrefix("public ") ||
                                trimmed.hasPrefix("private ") || trimmed.hasPrefix("func ")
            
            if isFunctionStart && !currentChunk.isEmpty && currentLength >= minChunkLength {
                chunks.append(buildChunk(content: currentChunk, fileName: fileName, type: "code"))
                currentChunk = line
                currentLength = line.count
            } else if currentLength + line.count > maxChunkLength && !currentChunk.isEmpty {
                // Always add chunk if it has content
                chunks.append(buildChunk(content: currentChunk, fileName: fileName, type: "code"))
                currentChunk = line
                currentLength = line.count
            } else {
                if !currentChunk.isEmpty {
                    currentChunk += "\n" + line
                } else {
                    currentChunk = line
                }
                currentLength = currentChunk.count
            }
        }
        
        // Always add final chunk if it has content
        if !currentChunk.isEmpty {
            chunks.append(buildChunk(content: currentChunk, fileName: fileName, type: "code"))
        }
        
        return Array(chunks.prefix(800)) // Increased from 400 to 800
    }
    
    private func chunkText(text: String, fileName: String) -> [String] {
        // Text-specific chunking with sentence awareness - more inclusive
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        var chunks: [String] = []
        var currentChunk = ""
        let maxChunkLength = 800 // Reduced from 1600 to 800 for more chunks
        let minChunkLength = 30 // Even lower minimum
        
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            if currentChunk.count + trimmed.count > maxChunkLength && !currentChunk.isEmpty {
                // Always add chunk if it has content
                chunks.append(buildChunk(content: currentChunk, fileName: fileName, type: "text"))
                currentChunk = trimmed
            } else {
                if !currentChunk.isEmpty {
                    currentChunk += ". " + trimmed
                } else {
                    currentChunk = trimmed
                }
            }
        }
        
        // Always add final chunk if it has content
        if !currentChunk.isEmpty {
            chunks.append(buildChunk(content: currentChunk, fileName: fileName, type: "text"))
        }
        
        // If no sentences found, fall back to line-based chunking
        if chunks.isEmpty {
            return chunkGeneric(text: text, fileName: fileName)
        }
        
        return Array(chunks.prefix(800)) // Increased from 400 to 800
    }
    
    private func chunkGeneric(text: String, fileName: String) -> [String] {
        // Generic chunking for unknown file types - more inclusive
        let lines = text.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentChunk = ""
        var currentLength = 0
        let maxChunkLength = 750 // Reduced from 1500 to 750 for more chunks
        let minChunkLength = 30 // Even lower minimum
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                if !currentChunk.isEmpty && currentLength >= minChunkLength {
                    chunks.append(buildChunk(content: currentChunk, fileName: fileName, type: "generic"))
                    currentChunk = ""
                    currentLength = 0
                }
                continue
            }
            
            if currentLength + trimmed.count > maxChunkLength && !currentChunk.isEmpty {
                // Always add chunk if it has content
                chunks.append(buildChunk(content: currentChunk, fileName: fileName, type: "generic"))
                currentChunk = trimmed
                currentLength = trimmed.count
            } else {
                if !currentChunk.isEmpty {
                    currentChunk += "\n" + trimmed
                } else {
                    currentChunk = trimmed
                }
                currentLength = currentChunk.count
            }
        }
        
        // Always add final chunk if it has content
        if !currentChunk.isEmpty {
            chunks.append(buildChunk(content: currentChunk, fileName: fileName, type: "generic"))
        }
        
        return Array(chunks.prefix(600)) // Increased from 300 to 600
    }
    
    private func buildChunk(content: String, fileName: String, type: String) -> String {
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        **Source:** \(fileName) (\(type))
        **Content:**
        \(cleanContent)
        """
    }
}

