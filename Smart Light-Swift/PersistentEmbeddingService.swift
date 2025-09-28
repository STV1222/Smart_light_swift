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
    
    // Batch processing - optimized for large files
    private let maxBatchSize = 5 // Process up to 5 texts at once for stability
    
    init(modelName: String) throws {
        self.modelName = modelName
        
        try startPersistentProcess()
    }
    
    deinit {
        stopPersistentProcess()
    }
    
    private func startPersistentProcess() throws {
        print("[PersistentEmbeddingService] Starting persistent process initialization...")
        let process = Process()
        
        // Use the project's Python environment
        let projectRoot = "/Users/stv/Desktop/Business/Smart light"
        let venvPython = "\(projectRoot)/.venv/bin/python3"
        
        print("[PersistentEmbeddingService] Checking Python environment at: \(venvPython)")
        
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            process.executableURL = URL(fileURLWithPath: venvPython)
            print("[PersistentEmbeddingService] Using virtual environment Python: \(venvPython)")
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"]
            print("[PersistentEmbeddingService] Using system Python (venv not found)")
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
        
        // Set up environment with memory optimization
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["OMP_NUM_THREADS"] = "2" // Limit CPU threads to reduce memory usage
        env["MKL_NUM_THREADS"] = "2"
        env["OPENBLAS_NUM_THREADS"] = "2"
        env["VECLIB_MAXIMUM_THREADS"] = "2"
        env["NUMEXPR_NUM_THREADS"] = "2"
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
            if let content = try? String(contentsOf: fileURL, encoding: .utf8),
               let loaded = parseDotEnv(content), !loaded.isEmpty {
                loaded.forEach { env[$0.key] = $0.value }
            }
        }
        
        process.environment = env
        
        do {
            try process.run()
            print("[PersistentEmbeddingService] Python process started successfully")
        } catch {
            print("[PersistentEmbeddingService] Failed to start Python process: \(error)")
            throw error
        }
        
        self.pythonProcess = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        
        // Wait for process to be ready
        do {
            try waitForProcessReady()
            print("[PersistentEmbeddingService] Process ready signal received")
        } catch {
            print("[PersistentEmbeddingService] Failed to receive ready signal: \(error)")
            // Try to read error output for debugging
            let errorData = errorPipe.fileHandleForReading.availableData
            if let errorString = String(data: errorData, encoding: .utf8), !errorString.isEmpty {
                print("[PersistentEmbeddingService] Python error output: \(errorString)")
            }
            throw error
        }
        
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
import struct

# Add project root to path
project_root = "/Users/stv/Desktop/Business/Smart light"
sys.path.insert(0, project_root)

# Set tokenizer parallelism to avoid warnings
os.environ['TOKENIZERS_PARALLELISM'] = 'false'

try:
    print("Starting persistent embedding service...", file=sys.stderr)
    import gc
    try:
        import psutil
        psutil_available = True
    except ImportError:
        print("psutil not available, skipping memory monitoring", file=sys.stderr)
        psutil_available = False
    
    from sentence_transformers import SentenceTransformer
    import numpy as np
    
    # Set memory limits and optimization
    if psutil_available:
        print(f"Available memory: {psutil.virtual_memory().available / (1024**3):.1f} GB", file=sys.stderr)
    else:
        print("Memory monitoring not available", file=sys.stderr)
    
    print("Loading model...", file=sys.stderr)
    model = SentenceTransformer('\(modelName)')
    
    # Optimize model for memory usage
    if hasattr(model, 'max_seq_length'):
        model.max_seq_length = 512  # Limit sequence length to reduce memory usage
    print("Model loaded successfully", file=sys.stderr)
    
    # Signal that we're ready
    print("READY", file=sys.stderr)
    sys.stderr.flush()
    
    def send_response(data):
        '''Send data with length header for proper synchronization'''
        json_str = json.dumps(data)
        json_bytes = json_str.encode('utf-8')
        length = len(json_bytes)
        
        # Send length header (4 bytes, big-endian)
        length_header = struct.pack('>I', length)
        sys.stdout.buffer.write(length_header)
        sys.stdout.buffer.flush()
        
        # Send the actual JSON data
        sys.stdout.buffer.write(json_bytes)
        sys.stdout.buffer.flush()
        
        print(f"Sent response: {len(json_str)} characters, {len(json_bytes)} bytes", file=sys.stderr)
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
                
                # Generate embeddings with error handling and memory management
                try:
                    # Check memory before processing
                    if psutil_available:
                        memory_before = psutil.virtual_memory().used / (1024**3)
                        print(f"Memory before embedding: {memory_before:.1f} GB", file=sys.stderr)
                    else:
                        print("Processing embedding...", file=sys.stderr)
                    
                    # Process in smaller batches if text is very long
                    if any(len(text) > 10000 for text in texts):
                        print("Large text detected, using batch processing", file=sys.stderr)
                        all_embeddings = []
                        for text in texts:
                            if text_type == 'query':
                                emb = model.encode_query([text])
                            else:
                                emb = model.encode_document([text])
                            all_embeddings.extend(emb.tolist())
                            # Force garbage collection after each text
                            gc.collect()
                        result = all_embeddings
                    else:
                        if text_type == 'query':
                            embeddings = model.encode_query(texts)
                        else:
                            embeddings = model.encode_document(texts)
                        result = embeddings.tolist()
                    
                    # Send result with length header
                    send_response(result)
                    
                    # Clean up memory
                    del result
                    if 'embeddings' in locals():
                        del embeddings
                    if 'all_embeddings' in locals():
                        del all_embeddings
                    gc.collect()
                    
                    if psutil_available:
                        memory_after = psutil.virtual_memory().used / (1024**3)
                        print(f"Memory after embedding: {memory_after:.1f} GB", file=sys.stderr)
                    else:
                        print("Embedding completed", file=sys.stderr)
                    
                except Exception as emb_error:
                    print(f"Embedding generation error: {str(emb_error)}", file=sys.stderr)
                    error_response = {"error": str(emb_error)}
                    send_response(error_response)
                    
            else:
                # No input, continue waiting
                continue
                
        except Exception as e:
            print(f"Error processing batch: {str(e)}", file=sys.stderr)
            import traceback
            traceback.print_exc(file=sys.stderr)
            error_response = {"error": str(e)}
            send_response(error_response)
            
except Exception as e:
    print(f"Critical error in persistent embedding service: {str(e)}", file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    print("FAILED", file=sys.stderr)  # Signal failure
    sys.stderr.flush()
    sys.exit(1)
"""
    }
    
    private func waitForProcessReady() throws {
        guard let errorPipe = errorPipe else { 
            print("[PersistentEmbeddingService] Error: errorPipe is nil")
            return 
        }
        
        let timeout = 30.0 // 30 seconds timeout
        let startTime = Date()
        var allOutput = ""
        
        print("[PersistentEmbeddingService] Waiting for READY signal from Python process...")
        
        while Date().timeIntervalSince(startTime) < timeout {
            let data = errorPipe.fileHandleForReading.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                allOutput += output
                print("[PersistentEmbeddingService] Python stderr: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                
                if output.contains("READY") {
                    print("[PersistentEmbeddingService] Process is ready")
                    return
                } else if output.contains("FAILED") {
                    print("[PersistentEmbeddingService] Python process reported failure")
                    throw NSError(domain: "Embedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Python process failed to initialize"])
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        print("[PersistentEmbeddingService] Timeout waiting for READY signal")
        print("[PersistentEmbeddingService] All Python output received: \(allOutput)")
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
                
                // Check if it's a truncation error or communication issue
                if let nsError = error as NSError?, nsError.domain == "Embedding" && nsError.code == -2 {
                    let description = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? ""
                    if description.contains("truncated") || description.contains("buffer limit") || description.contains("No response") {
                        print("[PersistentEmbeddingService] Detected communication error, restarting process")
                        // The process restart will be handled below
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
        // Process in optimized batches for large files
        var allEmbeddings: [[Float]] = []
        let batchSize = maxBatchSize
        
        let totalBatches = (texts.count + batchSize - 1) / batchSize
        
        print("[PersistentEmbeddingService] Processing \(texts.count) texts in \(totalBatches) batches (batch size: \(batchSize))")
        
        for i in stride(from: 0, to: texts.count, by: batchSize) {
            let endIndex = min(i + batchSize, texts.count)
            let batch = Array(texts[i..<endIndex])
            let batchNumber = i/batchSize + 1
            
            print("[PersistentEmbeddingService] Processing batch \(batchNumber)/\(totalBatches) with \(batch.count) texts")
            if batch.count == 1 {
                print("[PersistentEmbeddingService] Single text length: \(batch[0].count) characters")
            } else {
                let totalChars = batch.map { $0.count }.reduce(0, +)
                print("[PersistentEmbeddingService] Batch total characters: \(totalChars)")
            }
            
            // Update progress for this embedding batch
            let embeddingProgress = Double(batchNumber) / Double(totalBatches)
            progress?(embeddingProgress)
            
            let batchEmbeddings = try processBatch(batch, asQuery: asQuery)
            allEmbeddings.append(contentsOf: batchEmbeddings)
            print("[PersistentEmbeddingService] ✅ Completed batch \(batchNumber)/\(totalBatches) - \(batchEmbeddings.count) embeddings")
        }
        
        print("[PersistentEmbeddingService] ✅ Completed all batches: \(allEmbeddings.count) total embeddings")
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
        
        // Wait for response with length-header protocol (with fallback to old method)
        let timeout = 60.0 // Increased timeout to 60 seconds
        let startTime = Date()
        var outputData = Data()
        var isComplete = false
        var lastDataTime = Date()
        var consecutiveEmptyReads = 0
        let maxEmptyReads = 10 // Allow up to 10 consecutive empty reads before giving up
        var expectedLength: Int? = nil
        var headerRead = false
        var fallbackMode = false
        
        print("[PersistentEmbeddingService] Waiting for response from Python process...")
        
        while Date().timeIntervalSince(startTime) < timeout && !isComplete {
            let availableData = outputPipe.fileHandleForReading.availableData
            if !availableData.isEmpty {
                outputData.append(availableData)
                lastDataTime = Date()
                consecutiveEmptyReads = 0 // Reset empty read counter
                print("[PersistentEmbeddingService] Received \(availableData.count) bytes, total: \(outputData.count) bytes")
                
                // First, read the length header (4 bytes, big-endian)
                if !headerRead && !fallbackMode && outputData.count >= 4 {
                    let headerData = outputData.prefix(4)
                    let lengthBytes = [UInt8](headerData)
                    
                    // Check if this looks like a length header (reasonable values)
                    let calculatedLength = Int(lengthBytes[0]) << 24 | Int(lengthBytes[1]) << 16 | Int(lengthBytes[2]) << 8 | Int(lengthBytes[3])
                    
                    // If length looks reasonable, use new protocol (max 10MB for embeddings)
                    if calculatedLength > 0 && calculatedLength <= 10_000_000 {
                        expectedLength = calculatedLength
                        outputData = Data(outputData.dropFirst(4)) // Remove header from data
                        headerRead = true
                        print("[PersistentEmbeddingService] Using new length-header protocol")
                        print("[PersistentEmbeddingService] Expected response length: \(expectedLength ?? 0) bytes")
                        print("[PersistentEmbeddingService] Length header bytes: \(lengthBytes.map { String($0) }.joined(separator: ", "))")
                    } else {
                        // Check if this might be the start of JSON data instead of a header
                        if let testString = String(data: outputData.prefix(10), encoding: .utf8), testString.hasPrefix("[") {
                            print("[PersistentEmbeddingService] Data starts with JSON, falling back to JSON detection")
                            fallbackMode = true
                        } else {
                            print("[PersistentEmbeddingService] Length header looks invalid (\(calculatedLength) bytes - too large), falling back to JSON detection")
                            fallbackMode = true
                        }
                    }
                }
                
                // Fallback: Try to detect complete JSON using old method
                if fallbackMode && !isComplete {
                    if let outputString = String(data: outputData, encoding: .utf8) {
                        // Look for complete JSON array
                        if outputString.hasPrefix("[") && (outputString.hasSuffix("]") || outputString.hasSuffix("]\n")) {
                            // Try to parse to see if it's valid JSON
                            if let _ = try? JSONSerialization.jsonObject(with: outputData) {
                                print("[PersistentEmbeddingService] Complete JSON response detected (fallback mode)")
                                isComplete = true
                                break
                            }
                        }
                    }
                }
                
                // If we have the header and enough data, we have a complete response
                if let expectedLen = expectedLength {
                    if outputData.count >= expectedLen {
                        outputData = Data(outputData.prefix(expectedLen)) // Truncate to expected length
                        print("[PersistentEmbeddingService] Complete response received (\(outputData.count) bytes)")
                        isComplete = true
                        break
                    } else {
                        // Still waiting for more data
                        print("[PersistentEmbeddingService] Waiting for \(expectedLen - outputData.count) more bytes")
                    }
                }
            } else {
                consecutiveEmptyReads += 1
                
                // Check if we've been waiting too long without data
                let timeSinceLastData = Date().timeIntervalSince(lastDataTime)
                if timeSinceLastData > 2.0 && consecutiveEmptyReads > maxEmptyReads {
                    print("[PersistentEmbeddingService] No data received for \(timeSinceLastData) seconds, stopping")
                    break
                }
                
                if Date().timeIntervalSince(startTime) > timeout {
                    print("[PersistentEmbeddingService] Timeout reached, breaking")
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05) // Reduced sleep time for more responsive reading
        }
        
        guard !outputData.isEmpty else {
            throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response from embedding process"])
        }
        
        // Try to parse the JSON response
        print("[PersistentEmbeddingService] Attempting to parse JSON response (\(outputData.count) bytes)")
        let result: Any
        do {
            result = try JSONSerialization.jsonObject(with: outputData)
            print("[PersistentEmbeddingService] ✅ JSON parsing successful")
        } catch {
            print("[PersistentEmbeddingService] JSON parsing failed: \(error)")
            print("[PersistentEmbeddingService] Raw response length: \(outputData.count)")
            
            // Log the first and last 100 characters for debugging
            if let debugString = String(data: outputData, encoding: .utf8) {
                let first100 = String(debugString.prefix(100))
                let last100 = String(debugString.suffix(100))
                print("[PersistentEmbeddingService] Response start: \(first100)")
                print("[PersistentEmbeddingService] Response end: \(last100)")
            }
            
            // Check if response was truncated at common buffer boundaries
            if outputData.count == 4096 || outputData.count == 8192 || outputData.count == 12288 {
                print("[PersistentEmbeddingService] Response appears to be truncated at \(outputData.count) characters")
                print("[PersistentEmbeddingService] This suggests a buffer size limit in pipe communication")
                
                throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "Response truncated due to buffer limit - will retry with smaller batch"])
            }
            
            throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON response: \(error.localizedDescription)"])
        }
        
        if let errorDict = result as? [String: Any], let error = errorDict["error"] as? String {
            throw NSError(domain: "Embedding", code: -3, userInfo: [NSLocalizedDescriptionKey: "Embedding error: \(error)"])
        }
        
        if let embeddings = result as? [[Double]] {
            print("[PersistentEmbeddingService] ✅ Successfully processed \(embeddings.count) embeddings")
            return embeddings.map { $0.map { Float($0) } }
        } else if let embeddings = result as? [[NSNumber]] {
            print("[PersistentEmbeddingService] ✅ Successfully processed \(embeddings.count) embeddings (NSNumber format)")
            return embeddings.map { $0.map { $0.floatValue } }
        } else {
            print("[PersistentEmbeddingService] ❌ Unexpected embedding response format: \(type(of: result))")
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
