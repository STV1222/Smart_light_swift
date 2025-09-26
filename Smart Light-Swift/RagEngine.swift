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
        let storeCount = store.count
        print("[RagEngine] Store has \(storeCount) chunks")
        print("[RagEngine] Store object: \(ObjectIdentifier(store))")
        if storeCount == 0 {
            print("[RagEngine] No chunks in store, providing general answer")
            return try await generalAnswer(question: question)
        }
        
        // Debug: Show what's in the store
        let allChunks = store.allChunks()
        print("[RagEngine] Sample chunks:")
        for (i, chunk) in allChunks.prefix(3).enumerated() {
            print("[RagEngine] Chunk \(i): \(chunk.path) - \(String(chunk.text.prefix(100)))...")
        }
        
        // Advanced search with multiple strategies
        let qEmb = try embedder.embed(texts: [question], asQuery: true, progress: nil).first ?? []
        
        // Get maximum initial results for comprehensive coverage
        let initialHits = store.topK(query: qEmb, k: 200) // Increased from 100 to 200
        
        // Apply semantic reranking for better quality
        let rerankedHits = rerankResults(query: question, hits: initialHits)
        
        // Take maximum results after reranking for comprehensive answers
        let hits = Array(rerankedHits.prefix(80)) // Increased from 40 to 80
        
        print("[RagEngine] Found \(hits.count) hits for query: \(question)")
        for (i, hit) in hits.prefix(5).enumerated() {
            print("[RagEngine] Hit \(i): score=\(hit.score), path=\(hit.chunk.path)")
        }
        
        // More lenient confidence scoring to capture all relevant chunks
        let maxScore = hits.first?.score ?? 0.0
        let avgScore = hits.isEmpty ? 0.0 : hits.map { $0.score }.reduce(0, +) / Float(hits.count)
        let lowConfidence = hits.isEmpty || maxScore < 0.05 || avgScore < 0.03 || hits.count < 1
        
        if lowConfidence {
            // Low confidence or no relevant chunks found, provide general answer
            print("[RagEngine] Low confidence: maxScore=\(maxScore), avgScore=\(avgScore), hits=\(hits.count)")
            return try await generalAnswer(question: question)
        }
        
        print("[RagEngine] Using \(hits.count) chunks with maxScore=\(maxScore), avgScore=\(avgScore)")
        
        // Build prompt with maximum context - use ALL hits to ensure no companies are missed
        let (systemMsg, userMsg) = buildPrompt(query: question, hits: hits, nCtx: hits.count) // Use all available hits
        
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
                    let citations = buildCitations(from: ArraySlice(hits), response: aiResponse)
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
            // Build enhanced context with better organization
            var snippets: [String] = []
            for (i, hit) in hits.prefix(nCtx).enumerated() {
                let path = hit.chunk.path.components(separatedBy: "#p").first ?? hit.chunk.path
                let page = hit.chunk.path.contains("#p") ? hit.chunk.path.components(separatedBy: "#p").last : nil
                let tag = page != nil ? "\(path):p\(page!)" : path
                let score = String(format: "%.3f", hit.score)
                let text = String(hit.chunk.text.prefix(30000)) // Increased to 30000 for maximum context
                let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n\n", with: "\n")
                snippets.append("[\(i + 1)] (Relevance: \(score)) \(tag)\n\(cleanText)")
            }
        
        let nowStr = formattedNow()
        let queryType = analyzeQueryType(query)
        
        let userMsg = """
        Current local time: \(nowStr)
        Query type: \(queryType)
        
        Question: \(query)
        
        Context snippets (numbered for inline citations):
        \(snippets.joined(separator: "\n---\n"))
        """
        
            let systemMsg = """
            You are an expert AI assistant with access to the user's personal knowledge base. Your role is to provide comprehensive, accurate, and well-structured answers based on the provided context.
            
            **CORE INSTRUCTIONS:**
            1. **PRIMARY SOURCE**: Use ONLY the information provided in the context snippets below
            2. **CITATION REQUIREMENT**: Every factual claim MUST be supported with [n] citations
            3. **COMPREHENSIVE ANALYSIS**: Provide detailed, thorough answers that fully address the question
            4. **COMPLETE ENUMERATION**: When asked to list items (like companies, documents, etc.), you MUST list ALL items mentioned in the context - do not miss any
            5. **STRUCTURE**: Organize responses with clear headings, bullet points, and logical flow
            6. **ACCURACY**: If information is missing or unclear, explicitly state this and suggest what's needed
            
            **RESPONSE GUIDELINES:**
            • Start with a direct answer to the question
            • For listing questions (like "what companies"), scan ALL context snippets and list EVERY relevant item found
            • Provide detailed explanations with specific examples from the context
            • Use [1], [2], etc. citations for every factual claim
            • Include relevant details, numbers, dates, and specific information
            • If multiple perspectives exist, present them clearly
            • End with a summary or key takeaways when appropriate
            
            **CITATION FORMAT:**
            • Use [n] format for all references
            • Citations should appear immediately after the relevant information
            • Example: "The project was completed in 2024 [1] and involved 5 team members [2]"
            
            **SPECIAL INSTRUCTION FOR LISTING QUESTIONS:**
            When asked to list companies, documents, or other items, carefully examine ALL context snippets and include every relevant item mentioned. Do not miss any items that appear in the context.
            """
        
        return (systemMsg, userMsg)
    }
    
    private func analyzeQueryType(_ query: String) -> String {
        let lowerQuery = query.lowercased()
        
        if lowerQuery.contains("what") || lowerQuery.contains("define") || lowerQuery.contains("explain") {
            return "Definition/Explanation"
        } else if lowerQuery.contains("how") || lowerQuery.contains("process") || lowerQuery.contains("steps") {
            return "Process/Procedure"
        } else if lowerQuery.contains("why") || lowerQuery.contains("reason") || lowerQuery.contains("cause") {
            return "Analysis/Reasoning"
        } else if lowerQuery.contains("when") || lowerQuery.contains("time") || lowerQuery.contains("date") {
            return "Temporal/Time-based"
        } else if lowerQuery.contains("where") || lowerQuery.contains("location") || lowerQuery.contains("place") {
            return "Location/Place"
        } else if lowerQuery.contains("who") || lowerQuery.contains("person") || lowerQuery.contains("people") {
            return "Person/Entity"
        } else if lowerQuery.contains("compare") || lowerQuery.contains("difference") || lowerQuery.contains("versus") {
            return "Comparison/Analysis"
        } else if lowerQuery.contains("list") || lowerQuery.contains("all") || lowerQuery.contains("every") {
            return "Enumeration/Listing"
        } else {
            return "General/Open-ended"
        }
    }

    private func containsCitations(_ text: String) -> Bool {
        // Check if the text contains citation references like [1], [2], etc.
        let citationPattern = #"\[\d+\]"#
        let regex = try? NSRegularExpression(pattern: citationPattern)
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex?.firstMatch(in: text, options: [], range: range) != nil
    }
    
    private func rerankResults(query: String, hits: [(score: Float, chunk: VectorChunk)]) -> [(score: Float, chunk: VectorChunk)] {
        // Advanced reranking algorithm for better relevance
        let queryWords = Set(query.lowercased().components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty })
        
        return hits.map { hit in
            var adjustedScore = hit.score
            
            // Boost score for exact word matches
            let chunkText = hit.chunk.text.lowercased()
            let chunkWords = Set(chunkText.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty })
            let wordMatches = queryWords.intersection(chunkWords)
            let wordMatchRatio = Float(wordMatches.count) / Float(max(queryWords.count, 1))
            adjustedScore += wordMatchRatio * 0.3
            
            // Boost score for title/header matches
            if chunkText.contains("title") || chunkText.contains("header") || chunkText.contains("#") {
                adjustedScore += 0.2
            }
            
            // Boost score for recent files (based on filename patterns)
            let fileName = hit.chunk.path.components(separatedBy: "/").last?.lowercased() ?? ""
            if fileName.contains("2024") || fileName.contains("latest") || fileName.contains("current") {
                adjustedScore += 0.15
            }
            
            // Boost score for code files when query seems technical
            let isTechnicalQuery = queryWords.contains { word in
                ["function", "class", "method", "api", "code", "programming", "algorithm", "data", "structure"].contains(word)
            }
            if isTechnicalQuery && (fileName.hasSuffix(".py") || fileName.hasSuffix(".js") || fileName.hasSuffix(".swift")) {
                adjustedScore += 0.2
            }
            
            // Boost score for document files when query seems informational
            let isInformationalQuery = queryWords.contains { word in
                ["what", "how", "why", "when", "where", "explain", "describe", "information", "details"].contains(word)
            }
            if isInformationalQuery && (fileName.hasSuffix(".pdf") || fileName.hasSuffix(".md") || fileName.hasSuffix(".txt")) {
                adjustedScore += 0.15
            }
            
            // Penalize very short chunks
            if hit.chunk.text.count < 100 {
                adjustedScore *= 0.8
            }
            
            // Penalize chunks with too much repetition
            let words = chunkText.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty }
            let uniqueWords = Set(words)
            let repetitionRatio = Float(uniqueWords.count) / Float(max(words.count, 1))
            if repetitionRatio < 0.5 {
                adjustedScore *= 0.7
            }
            
            return (score: min(adjustedScore, 1.0), chunk: hit.chunk)
        }.sorted { $0.score > $1.score }
    }
    
    private func buildCitations(from hits: ArraySlice<(score: Float, chunk: VectorChunk)>, response: String) -> String {
        guard !hits.isEmpty else { return "" }
        
        // Extract all citation numbers from the response
        let citationPattern = #"\[(\d+)\]"#
        let regex = try? NSRegularExpression(pattern: citationPattern)
        let range = NSRange(response.startIndex..<response.endIndex, in: response)
        let matches = regex?.matches(in: response, options: [], range: range) ?? []
        
        // Get unique citation numbers that are actually used
        let citedNumbers = Set(matches.compactMap { match in
            if let range = Range(match.range(at: 1), in: response) {
                return Int(String(response[range]))
            }
            return nil
        })
        
        // Only include sources that are actually cited
        var citationLines: [String] = []
        citationLines.append("**Sources:**")
        
        for (i, hit) in hits.enumerated() {
            let citationNumber = i + 1
            if citedNumbers.contains(citationNumber) {
                let path = hit.chunk.path.components(separatedBy: "#p").first ?? hit.chunk.path
                let page = hit.chunk.path.contains("#p") ? hit.chunk.path.components(separatedBy: "#p").last : nil
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                let folderName = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                
                // Include the full path for clickable citations
                let citation = "[\(citationNumber)] \(fileName)"
                let fullPath = path // Use the full path stored in the chunk
                if let page = page {
                    citationLines.append("\(citation) (page \(page)) - \(folderName) | \(fullPath)")
                } else {
                    citationLines.append("\(citation) - \(folderName) | \(fullPath)")
                }
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


