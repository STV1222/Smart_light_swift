import Foundation

struct DocumentChunk: Identifiable, Codable, Equatable {
    let id: UUID
    let path: String
    let text: String
    let embedding: [Float]
}

struct VectorChunk: Identifiable, Codable, Equatable {
    let id: UUID
    let path: String
    let text: String
    let embedding: [Float]
}

final class InMemoryVectorStore: @unchecked Sendable {
    private(set) var chunks: [DocumentChunk] = []
    private let dim: Int
    private let storeId = UUID()

    init(dimension: Int) { 
        self.dim = dimension
        print("[VectorStore] Created new store with ID: \(storeId)")
    }
    
    var count: Int { chunks.count }
    var dimension: Int { dim }

    func add(path: String, text: String, embedding: [Float]) {
        let chunk = DocumentChunk(id: UUID(), path: path, text: text, embedding: embedding)
        chunks.append(chunk)
        print("[VectorStore] Added chunk: \(path) (total: \(chunks.count)) to store \(storeId)")
    }

    func reset() { chunks.removeAll(keepingCapacity: false) }
    
    func allChunks() -> [VectorChunk] {
        return chunks.map { VectorChunk(id: $0.id, path: $0.path, text: $0.text, embedding: $0.embedding) }
    }

    func topK(query: [Float], k: Int = 20) -> [(score: Float, chunk: VectorChunk)] {
        let qn = l2norm(query)
        return chunks
            .map { chunk -> (Float, VectorChunk) in
                let sim = cosine(query, qn, chunk.embedding)
                let vectorChunk = VectorChunk(id: chunk.id, path: chunk.path, text: chunk.text, embedding: chunk.embedding)
                return (Float(sim), vectorChunk)
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


