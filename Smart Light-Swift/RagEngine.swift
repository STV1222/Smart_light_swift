import Foundation

final class RagEngine {
    private let embedder: EmbeddingService
    private let store: InMemoryVectorStore
    private let openAI = OpenAIService()

    init(embedder: EmbeddingService, store: InMemoryVectorStore) {
        self.embedder = embedder
        self.store = store
    }

    func answer(question: String) async throws -> String {
        // Special command to list indexed files (like Python version)
        let lower = question.lowercased()
        if lower.contains("list files") || lower.contains("what files are in my folder") {
            var lines: [String] = []
            let grouped = Dictionary(grouping: store.allChunks()) { chunk in
                let path = chunk.path.components(separatedBy: "#p").first ?? chunk.path
                return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            }
            for (dir, chunks) in grouped.sorted(by: { $0.key < $1.key }) {
                let fileList = Set(chunks.map { 
                    let path = $0.path.components(separatedBy: "#p").first ?? $0.path
                    return URL(fileURLWithPath: path).lastPathComponent 
                }).sorted().joined(separator: ", ")
                lines.append("- \(dir): \(fileList)")
            }
            if lines.isEmpty { 
                return "I don't have an index yet. Click 'Index folders…' in Settings, then try again." 
            }
            return "Indexed files I can see:\n\n" + lines.sorted().joined(separator: "\n")
        }
        
        // Check if we have any indexed data first
        print("[RagEngine] Store has \(store.count) chunks")
        if store.count == 0 {
            return try await generalAnswer(question: question)
        }
        
        // Debug: Show what's in the store
        let allChunks = store.allChunks()
        print("[RagEngine] Sample chunks:")
        for (i, chunk) in allChunks.prefix(3).enumerated() {
            print("[RagEngine] Chunk \(i): \(chunk.path) - \(String(chunk.text.prefix(100)))...")
        }
        
        // Search for relevant chunks using embeddings (like Python search function)
        let qEmb = try embedder.embed(texts: [question], asQuery: true).first ?? []
        let hits = store.topK(query: qEmb, k: 20) // Get more hits like Python (k=20)
        
        print("[RagEngine] Found \(hits.count) hits for query: \(question)")
        for (i, hit) in hits.prefix(3).enumerated() {
            print("[RagEngine] Hit \(i): score=\(hit.score), path=\(hit.chunk.path)")
        }
        
        // Check confidence based on scores (like Python logic)
        let maxScore = hits.first?.score ?? 0.0
        let lowConfidence = hits.isEmpty || maxScore < 0.2 || hits.count < 3
        
        if hits.isEmpty {
            // No relevant chunks found, provide general answer
            return try await generalAnswer(question: question)
        }
        
        // Build prompt with context like Python version
        let (systemMsg, userMsg) = buildPrompt(query: question, hits: hits, nCtx: 12)
        
        // Call AI with proper context
        let hasKey = (DotEnv.get("OPENAI_API_KEY") ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]) != nil
        if hasKey {
            do {
                let aiResponse = try await openAI.respond(userMsg, 
                                                        context: systemMsg,
                                                        reasoningEffort: "minimal",
                                                        verbosity: "low",
                                                        maxOutputTokens: 1000)
                
                // Only add citations if the response contains citation references
                if containsCitations(aiResponse) {
                    let citations = buildCitations(from: hits.prefix(12))
                    return aiResponse + "\n\n" + citations
                } else {
                    return aiResponse
                }
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        } else {
            // No API key, return context-based answer
            return "Based on your files, relevant points are:\n\n\(userMsg)"
        }
    }
    
    private func generalAnswer(question: String) async throws -> String {
        let hasKey = (DotEnv.get("OPENAI_API_KEY") ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]) != nil
        
        if hasKey {
            let nowStr = formattedNow()
            let systemMsg = "You are a helpful assistant. Answer the user's question generally and clearly. Do not reference any local files or claim knowledge of the user's documents."
            let userMsg = "Current local time: \(nowStr)\n\nQuestion: \(question)"
            
            do {
                return try await openAI.respond(userMsg, 
                                              context: systemMsg,
                                              reasoningEffort: "minimal",
                                              verbosity: "low",
                                              maxOutputTokens: 1000)
            } catch {
                return "I can answer general questions. To answer about your files, please index a folder first."
            }
        } else {
            return "I can answer general questions. To answer about your files, please index a folder first."
        }
    }
    
    private func buildPrompt(query: String, hits: [(score: Float, chunk: VectorChunk)], nCtx: Int) -> (String, String) {
        // Build numbered snippets like Python version
        var snippets: [String] = []
        for (i, hit) in hits.prefix(nCtx).enumerated() {
            let path = hit.chunk.path.components(separatedBy: "#p").first ?? hit.chunk.path
            let page = hit.chunk.path.contains("#p") ? hit.chunk.path.components(separatedBy: "#p").last : nil
            let tag = page != nil ? "\(path):p\(page!)" : path
            let text = String(hit.chunk.text.prefix(12000)) // Guardrail like Python
            let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n\n", with: "\n")
            snippets.append("[\(i + 1)] \(tag)\n\(cleanText)")
        }
        
        let nowStr = formattedNow()
        let userMsg = """
        Current local time: \(nowStr)
        
        Question: \(query)
        
        Context snippets (numbered for inline citations):
        \(snippets.joined(separator: "\n---\n"))
        """
        
        let systemMsg = """
        You are a meticulous assistant. Respond naturally and professionally, tailored to the question.
        Style:
        • Write clear, concise paragraphs and bullets only when helpful.
        • Do not use rigid section headings like 'Overview', 'Limitations', or 'How can I help next'.
        • Support factual claims with inline numeric citations like [1], [2] referring to the provided snippets.
        • Never include raw file paths; only use [n] where relevant.
        • If key info seems missing, say so and suggest what to index next.
        Citations: place [n] immediately after the sentence or clause it supports.
        """
        
        return (systemMsg, userMsg)
    }

    private func containsCitations(_ text: String) -> Bool {
        // Check if the text contains citation references like [1], [2], etc.
        let citationPattern = #"\[\d+\]"#
        let regex = try? NSRegularExpression(pattern: citationPattern)
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex?.firstMatch(in: text, options: [], range: range) != nil
    }
    
    private func buildCitations(from hits: ArraySlice<(score: Float, chunk: VectorChunk)>) -> String {
        guard !hits.isEmpty else { return "" }
        
        var citationLines: [String] = []
        citationLines.append("**Sources:**")
        
        for (i, hit) in hits.enumerated() {
            let path = hit.chunk.path.components(separatedBy: "#p").first ?? hit.chunk.path
            let page = hit.chunk.path.contains("#p") ? hit.chunk.path.components(separatedBy: "#p").last : nil
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            let folderName = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            
            // Include the full path for clickable citations
            let citation = "[\(i + 1)] \(fileName)"
            let fullPath = path // Use the full path stored in the chunk
            if let page = page {
                citationLines.append("\(citation) (page \(page)) - \(folderName) | \(fullPath)")
            } else {
                citationLines.append("\(citation) - \(folderName) | \(fullPath)")
            }
        }
        
        return citationLines.joined(separator: "\n")
    }

    private func formattedNow() -> String {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.timeZone = .current
        fmt.dateStyle = .full
        fmt.timeStyle = .medium
        return fmt.string(from: Date())
    }

    private func fileNameContext(for question: String) -> String? {
        let qTokens = tokenize(question)
        guard !qTokens.isEmpty else { return nil }
        var scoreByFile: [String: Int] = [:]
        for chunk in store.chunks {
            let file = (chunk.path.components(separatedBy: "#").first ?? chunk.path)
            let base = (file as NSString).lastPathComponent.lowercased()
            var sc = 0
            for t in qTokens { if base.contains(t) { sc += 1 } }
            if sc > 0 { scoreByFile[file, default: 0] += sc }
        }
        let top = scoreByFile.sorted { $0.value > $1.value }.prefix(10)
        guard !top.isEmpty else { return nil }
        let lines = top.map { "- \(($0.key as NSString).lastPathComponent)" }
        return "Files that look related based on names:\n" + lines.joined(separator: "\n")
    }

    private func tokenize(_ text: String) -> [String] {
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }
}


