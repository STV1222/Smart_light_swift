import Foundation

struct OpenAIService {
    private var apiKey: String? {
        DotEnv.get("OPENAI_API_KEY") ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    // Use Responses API with GPT-5 Nano only
    func respond(_ message: String,
                 context: String? = nil,
                 reasoningEffort: String = "minimal",
                 verbosity: String = "low",
                 maxOutputTokens: Int = 512) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw NSError(domain: "OpenAI", code: 401, userInfo: [NSLocalizedDescriptionKey: "OPENAI_API_KEY missing in .env"])
        }

        let url = URL(string: "https://api.openai.com/v1/responses")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var input = message
        if let context, !context.isEmpty {
            input = "Using this context, answer the user. If the context is irrelevant, answer generally.\n\nContext:\n\(context)\n\nUser: \(message)"
        }

        let body: [String: Any] = [
            "model": "gpt-5-nano",
            "input": input,
            "max_output_tokens": maxOutputTokens,
            "reasoning": ["effort": reasoningEffort],
            "text": ["verbosity": verbosity]
        ]

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        let session = URLSession(configuration: cfg)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "OpenAI", code: (resp as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        // Parse GPT-5 Responses API response
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Try output_text first (most common response format)
            if let outputText = obj["output_text"] as? String, !outputText.isEmpty {
                return outputText
            }
            // Try output array format (for structured responses)
            if let outputs = obj["output"] as? [[String: Any]] {
                var pieces: [String] = []
                for item in outputs {
                    if let type = item["type"] as? String, type == "message",
                       let content = item["content"] as? [[String: Any]] {
                        for c in content {
                            if let t = c["text"] as? String, !t.isEmpty { 
                                pieces.append(t) 
                            }
                        }
                    }
                }
                if !pieces.isEmpty { 
                    return pieces.joined(separator: "\n") 
                }
            }
        }
        // Fallback: return raw JSON for debugging
        return String(data: data, encoding: .utf8) ?? ""
    }
}


