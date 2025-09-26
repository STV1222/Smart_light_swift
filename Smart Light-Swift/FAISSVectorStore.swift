import Foundation

// FAISS-based vector store for much faster search performance
final class FAISSVectorStore {
    private let dimension: Int
    private var chunks: [VectorChunk] = []
    private var faissIndex: Data?
    private let storeQueue = DispatchQueue(label: "faiss.store", qos: .userInitiated)
    
    init(dimension: Int) {
        self.dimension = dimension
    }
    
    var count: Int { chunks.count }
    
    func add(path: String, text: String, embedding: [Float]) {
        storeQueue.async {
            let chunk = VectorChunk(id: UUID(), path: path, text: text, embedding: embedding)
            self.chunks.append(chunk)
            
            // Rebuild FAISS index periodically (every 100 chunks)
            if self.chunks.count % 100 == 0 {
                self.rebuildFAISSIndex()
            }
        }
    }
    
    func reset() {
        storeQueue.async {
            self.chunks.removeAll(keepingCapacity: false)
            self.faissIndex = nil
        }
    }
    
    func allChunks() -> [VectorChunk] {
        return storeQueue.sync { chunks }
    }
    
    func topK(query: [Float], k: Int = 20) -> [(score: Float, chunk: VectorChunk)] {
        return storeQueue.sync {
            // If FAISS index is available, use it for faster search
            if let faissIndex = faissIndex, !faissIndex.isEmpty {
                return self.searchWithFAISS(query: query, k: k, faissIndex: faissIndex)
            } else {
                // Fallback to linear search
                return self.linearSearch(query: query, k: k)
            }
        }
    }
    
    private func rebuildFAISSIndex() {
        guard !chunks.isEmpty else { return }
        
        // Create FAISS index using Python subprocess
        let embeddings = chunks.map { $0.embedding }
        let faissIndex = createFAISSIndex(embeddings: embeddings)
        self.faissIndex = faissIndex
    }
    
    private func createFAISSIndex(embeddings: [[Float]]) -> Data? {
        // Convert embeddings to numpy array format
        let flatEmbeddings = embeddings.flatMap { $0 }
        let embeddingData = Data(bytes: flatEmbeddings, count: flatEmbeddings.count * MemoryLayout<Float>.size)
        
        // Create FAISS index using Python
        let pythonScript = """
import sys
import json
import numpy as np
import faiss
import struct

# Read embeddings from stdin
data = sys.stdin.buffer.read()
embeddings = struct.unpack(f'{len(data)//4}f', data)

# Reshape to 2D array
dim = \(dimension)
num_vectors = len(embeddings) // dim
embeddings_array = np.array(embeddings).reshape(num_vectors, dim).astype('float32')

# Create FAISS index
index = faiss.IndexFlatIP(dim)  # Inner product (cosine similarity)
index.add(embeddings_array)

# Serialize index
index_data = faiss.serialize_index(index)
print(len(index_data))
sys.stdout.buffer.write(index_data)
"""
        
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("create_faiss_index.py")
        try? pythonScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path]
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        
        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(embeddingData)
            inputPipe.fileHandleForWriting.closeFile()
            
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let indexData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                return indexData
            }
        } catch {
            print("[FAISSVectorStore] Failed to create FAISS index: \(error)")
        }
        
        return nil
    }
    
    private func searchWithFAISS(query: [Float], k: Int, faissIndex: Data) -> [(score: Float, chunk: VectorChunk)] {
        // Use FAISS for fast similarity search
        let pythonScript = """
import sys
import json
import numpy as np
import faiss
import struct

# Read query and index from stdin
query_data = sys.stdin.buffer.read()
query_embeddings, index_data = query_data.split(b'\\n', 1)

# Deserialize query
query = struct.unpack(f'{len(query_embeddings)//4}f', query_embeddings)
query_array = np.array(query).reshape(1, -1).astype('float32')

# Deserialize FAISS index
index = faiss.deserialize_index(index_data)

# Search
scores, indices = index.search(query_array, \(k))

# Return results
result = {
    'scores': scores[0].tolist(),
    'indices': indices[0].tolist()
}
print(json.dumps(result))
"""
        
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("search_faiss.py")
        try? pythonScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path]
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        
        do {
            try process.run()
            
            // Send query and index data
            let queryData = Data(bytes: query, count: query.count * MemoryLayout<Float>.size)
            let combinedData = queryData + Data("\n".utf8) + faissIndex
            inputPipe.fileHandleForWriting.write(combinedData)
            inputPipe.fileHandleForWriting.closeFile()
            
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if let result = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
                   let scores = result["scores"] as? [Double],
                   let indices = result["indices"] as? [Int] {
                    
                    var results: [(score: Float, chunk: VectorChunk)] = []
                    for (i, index) in indices.enumerated() {
                        if index < chunks.count {
                            let score = Float(scores[i])
                            let chunk = chunks[index]
                            results.append((score: score, chunk: chunk))
                        }
                    }
                    return results
                }
            }
        } catch {
            print("[FAISSVectorStore] FAISS search failed: \(error)")
        }
        
        // Fallback to linear search
        return linearSearch(query: query, k: k)
    }
    
    private func linearSearch(query: [Float], k: Int) -> [(score: Float, chunk: VectorChunk)] {
        let qn = l2norm(query)
        return chunks
            .map { chunk -> (Float, VectorChunk) in
                let sim = cosine(query, qn, chunk.embedding)
                return (Float(sim), chunk)
            }
            .sorted(by: { $0.0 > $1.0 })
            .prefix(k)
            .map { (score: $0.0, chunk: $0.1) }
    }
    
    private func l2norm(_ v: [Float]) -> [Double] {
        let d = v.map { Double($0) }
        let n = sqrt(d.reduce(0) { $0 + $1*$1 })
        guard n > 0 else { return d }
        return d.map { $0 / n }
    }
    
    private func cosine(_ q: [Float], _ qn: [Double], _ v: [Float]) -> Double {
        let vn = l2norm(v)
        let n = min(qn.count, vn.count)
        var s: Double = 0
        for i in 0..<n { s += qn[i] * vn[i] }
        return s
    }
}
