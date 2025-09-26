import Foundation
import Dispatch

// Persistent embedding service that keeps the model loaded in memory
final class PersistentEmbeddingService: @unchecked Sendable, EmbeddingService {
    private let modelName: String
    private(set) var dimension: Int = 768
    
    // Persistent Python process for embeddings
    private var pythonProcess: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private let processQueue = DispatchQueue(label: "embedding.process", qos: .userInitiated)
    private let embeddingQueue = DispatchQueue(label: "embedding.queue", qos: .userInitiated, attributes: .concurrent)
    
    // Batch processing (reduced to avoid buffer limits)
    private let maxBatchSize = 1 // Process 1 text at a time to avoid any buffer limits
    
    init(modelName: String) throws {
        self.modelName = modelName
        
        try startPersistentProcess()
    }
    
    deinit {
        stopPersistentProcess()
    }
    
    private func startPersistentProcess() throws {
        let process = Process()
        
        // Use the project's Python environment
        let projectRoot = "/Users/stv/Desktop/Business/Smart light"
        let venvPython = "\(projectRoot)/.venv/bin/python3"
        
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            process.executableURL = URL(fileURLWithPath: venvPython)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"]
        }
        
        // Create persistent Python script
        let scriptContent = createPersistentScript()
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("persistent_embed_script.py")
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        
        process.arguments = (process.arguments ?? []) + [scriptURL.path]
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Set up environment
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        env.removeValue(forKey: "PYTHONHOME")
        
        if !FileManager.default.isExecutableFile(atPath: venvPython) {
            env["PYTHONPATH"] = projectRoot
        }
        
        // Load .env variables
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let candidateEnvFiles = [
            URL(fileURLWithPath: projectRoot).appendingPathComponent(".env"),
            homeDir.appendingPathComponent(".smartlight/.env"),
            homeDir.appendingPathComponent(".env")
        ]
        
        for fileURL in candidateEnvFiles {
            if let content = try? String(contentsOf: fileURL),
               let loaded = parseDotEnv(content), !loaded.isEmpty {
                loaded.forEach { env[$0.key] = $0.value }
            }
        }
        
        process.environment = env
        
        try process.run()
        
        self.pythonProcess = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        
        // Wait for process to be ready
        try waitForProcessReady()
        
        print("[PersistentEmbeddingService] Started persistent embedding process for \(modelName)")
    }
    
    private func createPersistentScript() -> String {
        return """
import sys
import json
import os
import time
import tempfile
from pathlib import Path

# Add project root to path
project_root = "/Users/stv/Desktop/Business/Smart light"
sys.path.insert(0, project_root)

# Set tokenizer parallelism to avoid warnings
os.environ['TOKENIZERS_PARALLELISM'] = 'false'

try:
    print("Starting persistent embedding service...", file=sys.stderr)
    from sentence_transformers import SentenceTransformer
    import numpy as np
    
    print("Loading model...", file=sys.stderr)
    model = SentenceTransformer('\(modelName)')
    print("Model loaded successfully", file=sys.stderr)
    
    # Signal that we're ready
    print("READY", file=sys.stderr)
    sys.stderr.flush()
    
    while True:
        try:
            # Read input from stdin with timeout
            import select
            import sys
            
            # Check if there's data available to read
            if select.select([sys.stdin], [], [], 1.0)[0]:  # 1 second timeout
                line = sys.stdin.readline()
                if not line:
                    break
                    
                # Parse input more carefully
                try:
                    data = json.loads(line.strip())
                except json.JSONDecodeError as e:
                    print(f"JSON decode error: {str(e)}", file=sys.stderr)
                    print(f"Input line: {line[:100]}...", file=sys.stderr)
                    continue
                    
                texts = data.get('texts', [])
                text_type = data.get('type', 'document')
                
                print(f"Processing {len(texts)} texts of type {text_type}", file=sys.stderr)
                
                # Generate embeddings with error handling
                try:
                    if text_type == 'query':
                        embeddings = model.encode_query(texts)
                    else:
                        embeddings = model.encode_document(texts)
                    
                    # Send result with proper error handling
                    result = embeddings.tolist()
                    json_output = json.dumps(result)
                    print(json_output)
                    sys.stdout.flush()
                    
                    print(f"Sent {len(result)} embeddings, JSON length: {len(json_output)}", file=sys.stderr)
                    sys.stderr.flush()
                    
                except Exception as emb_error:
                    print(f"Embedding generation error: {str(emb_error)}", file=sys.stderr)
                    error_response = json.dumps({"error": str(emb_error)})
                    print(error_response)
                    sys.stdout.flush()
                    
            else:
                # No input, continue waiting
                continue
                
        except Exception as e:
            print(f"Error processing batch: {str(e)}", file=sys.stderr)
            import traceback
            traceback.print_exc(file=sys.stderr)
            error_response = json.dumps({"error": str(e)})
            print(error_response)
            sys.stdout.flush()
            
except Exception as e:
    print(f"Fatal error: {str(e)}", file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
"""
    }
    
    private func waitForProcessReady() throws {
        guard let errorPipe = errorPipe else { return }
        
        let timeout = 30.0 // 30 seconds timeout
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            let data = errorPipe.fileHandleForReading.availableData
            if let output = String(data: data, encoding: .utf8), output.contains("READY") {
                print("[PersistentEmbeddingService] Process is ready")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        throw NSError(domain: "Embedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Persistent embedding process failed to start"])
    }
    
    private func stopPersistentProcess() {
        pythonProcess?.terminate()
        pythonProcess = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }
    
    func embed(texts: [String], asQuery: Bool = false, progress: ((Double) -> Void)? = nil) throws -> [[Float]] {
        var retryCount = 0
        let maxRetries = 3
        
        while retryCount < maxRetries {
            do {
                return try embedAsync(texts: texts, asQuery: asQuery, progress: progress)
            } catch {
                retryCount += 1
                print("[PersistentEmbeddingService] Embedding failed (attempt \(retryCount)/\(maxRetries)): \(error)")
                
                // Check if it's a truncation error
                if let nsError = error as NSError?, nsError.domain == "Embedding" && nsError.code == -2 {
                    let description = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? ""
                    if description.contains("truncated") || description.contains("buffer limit") {
                        print("[PersistentEmbeddingService] Detected truncation error, reducing batch size")
                        // Reduce batch size for next attempt
                        if maxBatchSize > 1 {
                            // This would require changing the property, but for now just restart
                        }
                    }
                }
                
                if retryCount < maxRetries {
                    // Try to restart the process
                    try restartProcess()
                    // Wait a bit before retrying
                    Thread.sleep(forTimeInterval: 1.0)
                } else {
                    throw error
                }
            }
        }
        
        throw NSError(domain: "Embedding", code: -5, userInfo: [NSLocalizedDescriptionKey: "Max retries exceeded"])
    }
    
    private func restartProcess() throws {
        print("[PersistentEmbeddingService] Restarting Python process...")
        stopPersistentProcess()
        try startPersistentProcess()
        print("[PersistentEmbeddingService] Python process restarted successfully")
    }
    
    private func embedAsync(texts: [String], asQuery: Bool = false, progress: ((Double) -> Void)? = nil) throws -> [[Float]] {
        // For now, process all requests immediately
        // TODO: Implement proper async batching later
        return try processEmbeddingRequest(texts: texts, asQuery: asQuery, progress: progress)
    }
    
    
    private func processEmbeddingRequest(texts: [String], asQuery: Bool, progress: ((Double) -> Void)? = nil) throws -> [[Float]] {
        // Process in small batches to avoid 4096 character limit
        var allEmbeddings: [[Float]] = []
        let batchSize = maxBatchSize
        
        let totalBatches = (texts.count + batchSize - 1) / batchSize
        
        for i in stride(from: 0, to: texts.count, by: batchSize) {
            let endIndex = min(i + batchSize, texts.count)
            let batch = Array(texts[i..<endIndex])
            let batchNumber = i/batchSize + 1
            
            print("[PersistentEmbeddingService] Processing batch \(batchNumber)/\(totalBatches) with \(batch.count) texts")
            if batch.count == 1 {
                print("[PersistentEmbeddingService] Single text length: \(batch[0].count) characters")
            }
            
            // Update progress for this embedding batch
            let embeddingProgress = Double(batchNumber) / Double(totalBatches)
            progress?(embeddingProgress)
            
            let batchEmbeddings = try processBatch(batch, asQuery: asQuery)
            allEmbeddings.append(contentsOf: batchEmbeddings)
        }
        
        return allEmbeddings
    }
    
    private func processBatch(_ texts: [String], asQuery: Bool) throws -> [[Float]] {
        guard let process = pythonProcess, process.isRunning,
              let inputPipe = inputPipe, let outputPipe = outputPipe else {
            throw NSError(domain: "Embedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Persistent embedding process not running"])
        }
        
        let payload: [String: Any] = [
            "texts": texts,
            "type": asQuery ? "query" : "document"
        ]
        
        let inputData = try JSONSerialization.data(withJSONObject: payload)
        let inputString = String(data: inputData, encoding: .utf8)! + "\n"
        
        print("[PersistentEmbeddingService] Sending batch of \(texts.count) texts, input size: \(inputString.count) chars")
        if texts.count == 1 {
            print("[PersistentEmbeddingService] Single text preview: \(String(texts[0].prefix(100)))...")
        }
        
        // Write to input pipe
        inputPipe.fileHandleForWriting.write(inputString.data(using: .utf8)!)
        
        // Wait for response with timeout
        let timeout = 30.0 // 30 seconds timeout
        let startTime = Date()
        var outputData = Data()
        var isComplete = false
        
        while Date().timeIntervalSince(startTime) < timeout && !isComplete {
            let availableData = outputPipe.fileHandleForReading.availableData
            if !availableData.isEmpty {
                outputData.append(availableData)
                
                // Try to parse JSON to check if it's complete
                if let outputString = String(data: outputData, encoding: .utf8) {
                    // Look for complete JSON array (starts with [ and ends with ] or newline)
                    if outputString.hasPrefix("[") && (outputString.hasSuffix("]") || outputString.hasSuffix("]\n")) {
                        // Try to parse to see if it's valid JSON
                        if let _ = try? JSONSerialization.jsonObject(with: outputData) {
                            isComplete = true
                            break
                        }
                    }
                }
            } else {
                // No data available, check if we've been waiting too long
                if Date().timeIntervalSince(startTime) > 10.0 {
                    print("[PersistentEmbeddingService] No data received for 10 seconds, breaking")
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        guard !outputData.isEmpty else {
            throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response from embedding process"])
        }
        
        guard let outputString = String(data: outputData, encoding: .utf8) else {
            throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to read embedding response"])
        }
        
        let trimmedOutput = outputString.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[PersistentEmbeddingService] Received response length: \(trimmedOutput.count) characters")
        
        guard let jsonData = trimmedOutput.data(using: .utf8) else {
            throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response to data"])
        }
        
        let result: Any
        do {
            result = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            print("[PersistentEmbeddingService] JSON parsing failed: \(error)")
            print("[PersistentEmbeddingService] Raw response length: \(trimmedOutput.count)")
            
            // Check if response was truncated
            if trimmedOutput.count == 20480 || trimmedOutput.count == 4096 {
                print("[PersistentEmbeddingService] Response appears to be truncated at \(trimmedOutput.count) characters")
                print("[PersistentEmbeddingService] This suggests a buffer size limit in pipe communication")
                
                // Try to restart the process and retry with even smaller batch
                throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "Response truncated due to buffer limit - will retry with smaller batch"])
            }
            
            throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON response: \(error.localizedDescription)"])
        }
        
        if let errorDict = result as? [String: Any], let error = errorDict["error"] as? String {
            throw NSError(domain: "Embedding", code: -3, userInfo: [NSLocalizedDescriptionKey: "Embedding error: \(error)"])
        }
        
        if let embeddings = result as? [[Double]] {
            return embeddings.map { $0.map { Float($0) } }
        } else if let embeddings = result as? [[NSNumber]] {
            return embeddings.map { $0.map { $0.floatValue } }
        } else {
            throw NSError(domain: "Embedding", code: -4, userInfo: [NSLocalizedDescriptionKey: "Unexpected embedding response format"])
        }
    }
    
    private func parseDotEnv(_ content: String) -> [String: String]? {
        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { continue }
            
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(trimmed[trimmed.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                result[key] = value
            }
        }
        return result
    }
}
