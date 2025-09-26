//
//  LocalEmbeddingService.swift
//  Smart Light-Swift
//

import Foundation

// Local embedding service that runs Python script in subprocess
final class LocalEmbeddingService: @unchecked Sendable, EmbeddingService {
    private let modelName: String
    private let pythonScript: String
    private(set) var dimension: Int = 768
    
    init(modelName: String) throws {
        self.modelName = modelName
        
        // Create a Python script for embedding following EmbeddingGemma usage
        let scriptContent = """
import sys
import json
import os
from pathlib import Path

# Add project root to path
project_root = "/Users/stv/Desktop/Business/Smart light"
sys.path.insert(0, project_root)

# Set tokenizer parallelism to avoid warnings
os.environ['TOKENIZERS_PARALLELISM'] = 'false'

try:
    print("Starting embedding process...", file=sys.stderr)
    from sentence_transformers import SentenceTransformer
    import numpy as np
    
    print("Loading model...", file=sys.stderr)
    # Load model with proper configuration for EmbeddingGemma
    model = SentenceTransformer('\(modelName)')
    
    print("Reading input...", file=sys.stderr)
    # Read input from stdin
    input_text = sys.stdin.read().strip()
    data = json.loads(input_text)
    
    texts = data.get('texts', [])
    text_type = data.get('type', 'document')  # 'query' or 'document'
    
    print(f"Processing {len(texts)} texts of type {text_type}", file=sys.stderr)
    
    # Generate embeddings using proper methods for EmbeddingGemma
    if text_type == 'query':
        print("Using encode_query...", file=sys.stderr)
        # Use encode_query for queries with search result prompt
        embeddings = model.encode_query(texts)
    else:
        print("Using encode_document...", file=sys.stderr)
        # Use encode_document for documents with title/text prompt
        embeddings = model.encode_document(texts)
    
    print(f"Generated embeddings shape: {embeddings.shape}", file=sys.stderr)
    
    # Convert to list format
    result = embeddings.tolist()
    
    print("Outputting result...", file=sys.stderr)
    # Output result as JSON
    print(json.dumps(result))
    sys.stdout.flush()  # Force flush stdout
    print("Done!", file=sys.stderr)
    sys.stderr.flush()  # Force flush stderr
    
except Exception as e:
    print(f"Error: {str(e)}", file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    print(json.dumps({"error": str(e)}), file=sys.stderr)
    sys.exit(1)
"""
        
        // Write script to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("embed_script.py")
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        
        self.pythonScript = scriptURL.path
        
        // Test the service works during initialization
        do {
            let testEmbeddings = try embed(texts: ["test"], asQuery: false)
            print("[LocalEmbeddingService] Test successful, got \(testEmbeddings.count) embeddings with \(testEmbeddings.first?.count ?? 0) dimensions")
        } catch {
            print("[LocalEmbeddingService] Test failed: \(error)")
            throw error
        }
    }
    
    deinit {
        // Clean up temporary script
        try? FileManager.default.removeItem(atPath: pythonScript)
    }
    
    func embed(texts: [String], asQuery: Bool = false, progress: ((Double) -> Void)? = nil) throws -> [[Float]] {
        print("[LocalEmbeddingService] Embedding \(texts.count) texts (asQuery: \(asQuery))")
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
        
        process.arguments = (process.arguments ?? []) + [pythonScript]
        
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
        
        // CRITICAL: Unset PYTHONHOME to prevent encodings module errors
        env.removeValue(forKey: "PYTHONHOME")
        
        // Don't set PYTHONPATH when using venv - let it handle its own configuration
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
            if let content = try? String(contentsOf: fileURL, encoding: .utf8),
               let loaded = parseDotEnv(content), !loaded.isEmpty {
                loaded.forEach { env[$0.key] = $0.value }
            }
        }
        
        process.environment = env
        
        do {
            try process.run()
            
            // Send input with proper format for EmbeddingGemma
            let payload: [String: Any] = [
                "texts": texts,
                "type": asQuery ? "query" : "document"
            ]
            let inputData = try JSONSerialization.data(withJSONObject: payload)
            inputPipe.fileHandleForWriting.write(inputData)
            inputPipe.fileHandleForWriting.closeFile()
            
            // Add timeout to prevent hanging
            let timeout = 60.0 // 60 seconds timeout
            let startTime = Date()
            while process.isRunning {
                if Date().timeIntervalSince(startTime) > timeout {
                    process.terminate()
                    throw NSError(domain: "Embedding", code: -7, userInfo: [NSLocalizedDescriptionKey: "Python script timed out after \(timeout) seconds"])
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            // Always read stderr for debugging
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let errorString = String(data: errorData, encoding: .utf8), !errorString.isEmpty {
                print("[LocalEmbeddingService] Python stderr: \(errorString)")
            }
            
            if process.terminationStatus != 0 {
                if let errorString = String(data: errorData, encoding: .utf8), !errorString.isEmpty {
                    throw NSError(domain: "Embedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Python script failed: \(errorString)"])
                }
                throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "Python script failed with status \(process.terminationStatus)"])
            }
            
            // Read output
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let outputString = String(data: outputData, encoding: .utf8) else {
                throw NSError(domain: "Embedding", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to read Python script output"])
            }
            
            let jsonData = outputString.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)!
            let result = try JSONSerialization.jsonObject(with: jsonData)
            
            // Check for error in response
            if let errorDict = result as? [String: Any], let error = errorDict["error"] as? String {
                throw NSError(domain: "Embedding", code: -4, userInfo: [NSLocalizedDescriptionKey: "Python script error: \(error)"])
            }
            
            if let embeddings = result as? [[Double]] {
                let result = embeddings.map { $0.map { Float($0) } }
                print("[LocalEmbeddingService] Successfully generated \(result.count) embeddings with \(result.first?.count ?? 0) dimensions")
                return result
            } else if let embeddings = result as? [[NSNumber]] {
                let result = embeddings.map { $0.map { $0.floatValue } }
                print("[LocalEmbeddingService] Successfully generated \(result.count) embeddings with \(result.first?.count ?? 0) dimensions")
                return result
            } else {
                throw NSError(domain: "Embedding", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unexpected output format from Python script"])
            }
            
        } catch {
            throw NSError(domain: "Embedding", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to run Python script: \(error.localizedDescription)"])
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
        return result.isEmpty ? nil : result
    }
}
