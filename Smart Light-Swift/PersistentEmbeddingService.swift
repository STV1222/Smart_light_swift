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
    
    // Batch processing - optimized for large files and folders
    private let maxBatchSize = 3 // Reduced from 5 to 3 for better stability with large folders
    
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
        
        // Install psutil for memory monitoring
        let installPsutilScript = """
        import subprocess
        import sys
        try:
            import psutil
            print("psutil already available", file=sys.stderr)
        except ImportError:
            print("Installing psutil for memory monitoring...", file=sys.stderr)
            subprocess.check_call([sys.executable, "-m", "pip", "install", "psutil"])
            print("psutil installed successfully", file=sys.stderr)
        """
        
        let psutilTempDir = FileManager.default.temporaryDirectory
        let psutilScriptURL = psutilTempDir.appendingPathComponent("install_psutil.py")
        try installPsutilScript.write(to: psutilScriptURL, atomically: true, encoding: .utf8)
        
        // Run psutil installation
        let installProcess = Process()
        installProcess.executableURL = URL(fileURLWithPath: venvPython)
        installProcess.arguments = [psutilScriptURL.path]
        installProcess.standardError = Pipe()
        try installProcess.run()
        installProcess.waitUntilExit()
        
        // Clean up
        try? FileManager.default.removeItem(at: psutilScriptURL)
        
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
        available_memory = psutil.virtual_memory().available / (1024**3)
        print(f"Available memory: {available_memory:.1f} GB", file=sys.stderr)
        # Warn if memory is low
        if available_memory < 2.0:
            print("WARNING: Low available memory detected. Processing may be unstable.", file=sys.stderr)
    else:
        print("Memory monitoring not available", file=sys.stderr)
    
    print("Loading model...", file=sys.stderr)
    model = SentenceTransformer('\(modelName)')
    
    # Optimize model for memory usage
    if hasattr(model, 'max_seq_length'):
        model.max_seq_length = 256  # Further reduced from 512 to 256 for better memory management
    print("Model loaded successfully", file=sys.stderr)
    
    # Signal that we're ready
    print("READY", file=sys.stderr)
    sys.stderr.flush()
    
    # CRITICAL: Redirect stdout to prevent any raw data from being sent
    import io
    original_stdout = sys.stdout
    sys.stdout = io.StringIO()  # Capture any accidental prints
    
    def send_response(data):
        '''Send data with length header for proper synchronization'''
        try:
            print(f"DEBUG: send_response called with data type: {type(data)}", file=sys.stderr)
            print(f"DEBUG: Data length: {len(data) if hasattr(data, '__len__') else 'N/A'}", file=sys.stderr)
            
            if isinstance(data, list) and len(data) > 0:
                print(f"DEBUG: First item type: {type(data[0])}", file=sys.stderr)
                print(f"DEBUG: First item preview: {str(data[0])[:100]}...", file=sys.stderr)
                if len(data) > 1:
                    print(f"DEBUG: Second item preview: {str(data[1])[:100]}...", file=sys.stderr)
            
            # Convert to JSON
            json_str = json.dumps(data)
            print(f"DEBUG: JSON string length: {len(json_str)}", file=sys.stderr)
            print(f"DEBUG: JSON preview: {json_str[:200]}...", file=sys.stderr)
            
            json_bytes = json_str.encode('utf-8')
            length = len(json_bytes)
            print(f"DEBUG: JSON bytes length: {length}", file=sys.stderr)
            
            # Send length header (4 bytes, big-endian)
            length_header = struct.pack('>I', length)
            print(f"DEBUG: Length header bytes: {[b for b in length_header]}", file=sys.stderr)
            original_stdout.buffer.write(length_header)
            original_stdout.buffer.flush()
            
            # Send the actual JSON data
            original_stdout.buffer.write(json_bytes)
            original_stdout.buffer.flush()
            
            print(f"DEBUG: Successfully sent {length} bytes", file=sys.stderr)
            print(f"Sent response: {len(json_str)} characters, {len(json_bytes)} bytes", file=sys.stderr)
            sys.stderr.flush()
            
        except Exception as e:
            print(f"CRITICAL ERROR in send_response: {e}", file=sys.stderr)
            import traceback
            traceback.print_exc(file=sys.stderr)
            # Try to send error as JSON
            try:
                error_data = {"error": str(e), "type": "send_response_error"}
                error_json = json.dumps(error_data)
                error_bytes = error_json.encode('utf-8')
                error_length = struct.pack('>I', len(error_bytes))
                original_stdout.buffer.write(error_length)
                original_stdout.buffer.write(error_bytes)
                original_stdout.buffer.flush()
            except:
                print("Failed to send error response", file=sys.stderr)
    
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
                    print(f"DEBUG: Starting embedding generation for {len(texts)} texts", file=sys.stderr)
                    print(f"DEBUG: Text type: {text_type}", file=sys.stderr)
                    print(f"DEBUG: First text preview: {texts[0][:100]}...", file=sys.stderr)
                    
                    # Check memory before processing
                    if psutil_available:
                        memory_before = psutil.virtual_memory().used / (1024**3)
                        print(f"Memory before embedding: {memory_before:.1f} GB", file=sys.stderr)
                    else:
                        print("Processing embedding...", file=sys.stderr)
                    
                    # Always process texts individually to prevent hanging on large inputs
                    print(f"Processing {len(texts)} texts individually to prevent hanging", file=sys.stderr)
                    all_embeddings = []
                    for i, text in enumerate(texts):
                        print(f"DEBUG: Processing text {i+1}/{len(texts)} (length: {len(text)})", file=sys.stderr)
                        try:
                            # Ensure text is not too long (should be handled by Swift side, but double-check)
                            if len(text) > 50000:
                                print(f"WARNING: Text too long ({len(text)} chars), truncating to 50000", file=sys.stderr)
                                text = text[:50000]
                            
                            # Process with timeout protection
                            import signal
                            def timeout_handler(signum, frame):
                                raise TimeoutError("Embedding generation timeout")
                            
                            # Set 30 second timeout for each text
                            signal.signal(signal.SIGALRM, timeout_handler)
                            signal.alarm(30)
                            
                            try:
                                if text_type == 'query':
                                    emb = model.encode_query([text])
                                else:
                                    emb = model.encode_document([text])
                                print(f"DEBUG: Generated embedding shape: {emb.shape}", file=sys.stderr)
                                all_embeddings.extend(emb.tolist())
                                
                                # Cancel timeout
                                signal.alarm(0)
                                
                            except TimeoutError:
                                print(f"ERROR: Timeout processing text {i+1}, using zero embedding", file=sys.stderr)
                                signal.alarm(0)
                                zero_embedding = [0.0] * 768
                                all_embeddings.append(zero_embedding)
                            except Exception as emb_error:
                                print(f"ERROR: Embedding generation failed for text {i+1}: {emb_error}", file=sys.stderr)
                                signal.alarm(0)
                                zero_embedding = [0.0] * 768
                                all_embeddings.append(zero_embedding)
                            
                            # Force garbage collection after each text
                            gc.collect()
                            
                            # Check memory after each text
                            if psutil_available:
                                memory_used = psutil.virtual_memory().used / (1024**3)
                                if memory_used > 2.0:  # Reduced threshold to 2GB
                                    print(f"WARNING: High memory usage ({memory_used:.1f}GB), forcing garbage collection", file=sys.stderr)
                                    gc.collect()
                                    # Additional cleanup
                                    import torch
                                    if torch.cuda.is_available():
                                        torch.cuda.empty_cache()
                                    
                        except Exception as text_error:
                            print(f"ERROR processing text {i+1}: {text_error}", file=sys.stderr)
                            # Create a zero embedding to continue processing
                            zero_embedding = [0.0] * 768  # 768 is the embedding dimension
                            all_embeddings.append(zero_embedding)
                            print(f"WARNING: Using zero embedding for failed text {i+1}", file=sys.stderr)
                    
                    result = all_embeddings
                    print(f"DEBUG: Final result type: {type(result)}", file=sys.stderr)
                    print(f"DEBUG: Final result length: {len(result)}", file=sys.stderr)
                    
                    # Final cleanup before sending response
                    gc.collect()
                    if psutil_available:
                        memory_used = psutil.virtual_memory().used / (1024**3)
                        print(f"DEBUG: Final memory usage: {memory_used:.1f}GB", file=sys.stderr)
                    
                    print(f"DEBUG: About to call send_response with result", file=sys.stderr)
                    print(f"DEBUG: Result type: {type(result)}", file=sys.stderr)
                    print(f"DEBUG: Result length: {len(result) if hasattr(result, '__len__') else 'N/A'}", file=sys.stderr)
                    
                    # CRITICAL: Check if any data was accidentally sent to stdout
                    captured_output = sys.stdout.getvalue()
                    if captured_output:
                        print(f"WARNING: Captured stdout output: {captured_output[:200]}...", file=sys.stderr)
                        print("This indicates raw data was sent instead of using send_response()", file=sys.stderr)
                        # Clear the captured output
                        sys.stdout = io.StringIO()
                    
                    # CRITICAL: Ensure we always call send_response, never print raw data
                    if result is None:
                        print("ERROR: Result is None, cannot send", file=sys.stderr)
                        error_response = {"error": "Result is None"}
                        send_response(error_response)
                    else:
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
                    import traceback
                    traceback.print_exc(file=sys.stderr)
                    error_response = {"error": str(emb_error), "type": "embedding_error"}
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
            }
            
            // Check accumulated output, not just current chunk
            if allOutput.contains("READY") {
                print("[PersistentEmbeddingService] Process is ready")
                return
            } else if allOutput.contains("FAILED") {
                print("[PersistentEmbeddingService] Python process reported failure")
                throw NSError(domain: "Embedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Python process failed to initialize"])
            }
            
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        print("[PersistentEmbeddingService] Timeout waiting for READY signal")
        print("[PersistentEmbeddingService] All Python output received: \(allOutput)")
        throw NSError(domain: "Embedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Persistent embedding process failed to start"])
    }
    
    private func stopPersistentProcess() {
        print("[PersistentEmbeddingService] Stopping persistent embedding process...")
        
        // Force cleanup of pipes first
        inputPipe?.fileHandleForWriting.closeFile()
        outputPipe?.fileHandleForReading.closeFile()
        errorPipe?.fileHandleForReading.closeFile()
        
        // Terminate the process
        pythonProcess?.terminate()
        
        // Wait for process to exit with timeout
        let timeout = 5.0
        let startTime = Date()
        while pythonProcess?.isRunning == true && Date().timeIntervalSince(startTime) < timeout {
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        // Force kill if still running
        if pythonProcess?.isRunning == true {
            print("[PersistentEmbeddingService] Force killing Python process after timeout")
            pythonProcess?.terminate()
        }
        
        pythonProcess?.waitUntilExit()
        pythonProcess = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        
        // Force garbage collection
        autoreleasepool {
            // This will help clean up any remaining references
        }
        
        print("[PersistentEmbeddingService] Persistent embedding process stopped")
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
    
    private func embedAsync(texts: [String], asQuery: Bool, progress: ((Double) -> Void)? = nil) throws -> [[Float]] {
        var result: [[Float]] = []
        processQueue.sync {
            do {
                result = try processEmbeddingRequest(texts: texts, asQuery: asQuery, progress: progress)
            } catch {
                // Rethrow the error to be caught in the outer embed function
                // Since we're in sync, we can just let it propagate
            }
        }
        return result
    }
    
    
    private func processEmbeddingRequest(texts: [String], asQuery: Bool, progress: ((Double) -> Void)? = nil) throws -> [[Float]] {
        // ROBUST: Process one text at a time to prevent crashes
        var allEmbeddings: [[Float]] = []
        
        print("[PersistentEmbeddingService] ROBUST MODE: Processing \(texts.count) texts one at a time")
        
        for (index, text) in texts.enumerated() {
            let progressValue = Double(index) / Double(texts.count)
            progress?(progressValue)
            
            print("[PersistentEmbeddingService] Processing text \(index + 1)/\(texts.count) (length: \(text.count) chars)")
            
            do {
                // Process single text with timeout and retry
                let singleTextEmbedding = try processSingleText(text, asQuery: asQuery, retryCount: 0)
                allEmbeddings.append(singleTextEmbedding)
                print("[PersistentEmbeddingService] ✅ Successfully processed text \(index + 1)/\(texts.count)")
                
                // Small delay between texts to prevent overwhelming the system
                Thread.sleep(forTimeInterval: 0.1)
                
            } catch {
                print("[PersistentEmbeddingService] ❌ Failed to process text \(index + 1)/\(texts.count): \(error)")
                // Use zero embedding for failed text to continue processing
                let zeroEmbedding = Array(repeating: Float(0.0), count: 768) // 768 is the embedding dimension
                allEmbeddings.append(zeroEmbedding)
                print("[PersistentEmbeddingService] Using zero embedding for failed text \(index + 1)")
            }
        }
        
        print("[PersistentEmbeddingService] ✅ Completed all texts: \(allEmbeddings.count) total embeddings")
        return allEmbeddings
    }
    
    private func processSingleText(_ text: String, asQuery: Bool, retryCount: Int) throws -> [Float] {
        guard let process = pythonProcess, process.isRunning,
              let inputPipe = inputPipe, let outputPipe = outputPipe else {
            throw NSError(domain: "Embedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Persistent embedding process not running"])
        }
        
        // Clean and validate text
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = cleanedText.isEmpty ? "EMPTY_TEXT_PLACEHOLDER" : cleanedText
        
        // Truncate very long texts
        let maxLength = 10000 // Much smaller limit for single text processing
        let processedText = finalText.count > maxLength ? String(finalText.prefix(maxLength)) : finalText
        
        let payload: [String: Any] = [
            "texts": [processedText], // Single text in array
            "type": asQuery ? "query" : "document"
        ]
        
        let inputData = try JSONSerialization.data(withJSONObject: payload)
        let inputString = String(data: inputData, encoding: .utf8)! + "\n"
        
        print("[PersistentEmbeddingService] Sending single text (length: \(processedText.count) chars)")
        
        // Write to input pipe
        inputPipe.fileHandleForWriting.write(inputString.data(using: .utf8)!)
        
        // Wait for response with much shorter timeout
        let timeout = 30.0 // 30 second timeout for single text
        let startTime = Date()
        var outputData = Data()
        var isComplete = false
        var expectedLength: Int? = nil
        var headerRead = false
        
        print("[PersistentEmbeddingService] Waiting for single text response...")
        
        while Date().timeIntervalSince(startTime) < timeout && !isComplete {
            let availableData = outputPipe.fileHandleForReading.availableData
            if !availableData.isEmpty {
                outputData.append(availableData)
                print("[PersistentEmbeddingService] Received \(availableData.count) bytes, total: \(outputData.count) bytes")
            }
            
            // First, read the length header (4 bytes, big-endian)
            if !headerRead && outputData.count >= 4 {
                let headerData = outputData.prefix(4)
                let lengthBytes = [UInt8](headerData)
                let calculatedLength = Int(lengthBytes[0]) << 24 | Int(lengthBytes[1]) << 16 | Int(lengthBytes[2]) << 8 | Int(lengthBytes[3])
                
                if calculatedLength > 0 && calculatedLength <= 10_000_000 {
                    expectedLength = calculatedLength
                    outputData = Data(outputData.dropFirst(4)) // Remove header from data
                    headerRead = true
                    print("[PersistentEmbeddingService] Expected response length: \(expectedLength ?? 0) bytes")
                }
            }
            
            // If we have the header and enough data, we have a complete response
            if let expectedLen = expectedLength {
                if outputData.count >= expectedLen {
                    outputData = Data(outputData.prefix(expectedLen)) // Truncate to expected length
                    print("[PersistentEmbeddingService] Complete response received (\(outputData.count) bytes)")
                    isComplete = true
                    break
                }
            }
            
            // Check timeout
            if Date().timeIntervalSince(startTime) > timeout {
                print("[PersistentEmbeddingService] Timeout waiting for single text response")
                break
            }
            
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        // Parse the JSON response
        guard !outputData.isEmpty else {
            if retryCount < 2 {
                print("[PersistentEmbeddingService] No data received, retrying (attempt \(retryCount + 1))")
                Thread.sleep(forTimeInterval: 1.0)
                return try processSingleText(text, asQuery: asQuery, retryCount: retryCount + 1)
            }
            throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response from embedding process"])
        }
        
        do {
            let result = try JSONSerialization.jsonObject(with: outputData)
            
            // Check for error response
            if let errorDict = result as? [String: Any], let error = errorDict["error"] as? String {
                throw NSError(domain: "Embedding", code: -3, userInfo: [NSLocalizedDescriptionKey: "Embedding error: \(error)"])
            }
            
            // Parse embeddings
            if let embeddings = result as? [[Double]] {
                if let firstEmbedding = embeddings.first {
                    print("[PersistentEmbeddingService] ✅ Single text embedding received (dim: \(firstEmbedding.count))")
                    return firstEmbedding.map { Float($0) }
                }
            } else if let embeddings = result as? [[NSNumber]] {
                if let firstEmbedding = embeddings.first {
                    print("[PersistentEmbeddingService] ✅ Single text embedding received (dim: \(firstEmbedding.count))")
                    return firstEmbedding.map { $0.floatValue }
                }
            }
            
            throw NSError(domain: "Embedding", code: -4, userInfo: [NSLocalizedDescriptionKey: "Unexpected embedding response format"])
            
        } catch {
            print("[PersistentEmbeddingService] JSON parsing failed: \(error)")
            if retryCount < 2 {
                print("[PersistentEmbeddingService] Retrying single text processing (attempt \(retryCount + 1))")
                Thread.sleep(forTimeInterval: 1.0)
                return try processSingleText(text, asQuery: asQuery, retryCount: retryCount + 1)
            }
            throw error
        }
    }
    
    
    private func processBatch(_ texts: [String], asQuery: Bool) throws -> [[Float]] {
        guard let process = pythonProcess, process.isRunning,
              let inputPipe = inputPipe, let outputPipe = outputPipe else {
            throw NSError(domain: "Embedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Persistent embedding process not running"])
        }
        
        // Validate input before sending to prevent Python process issues
        let validatedTexts = texts.map { text in
            // Ensure text is not empty and not too long
            let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanedText.isEmpty {
                return "EMPTY_TEXT_PLACEHOLDER"
            }
            return cleanedText
        }
        
        let payload: [String: Any] = [
            "texts": validatedTexts,
            "type": asQuery ? "query" : "document"
        ]
        
        let inputData = try JSONSerialization.data(withJSONObject: payload)
        let inputString = String(data: inputData, encoding: .utf8)! + "\n"
        
        // Check if input is too large for pipe communication
        if inputString.count > 1_000_000 { // 1MB limit
            throw NSError(domain: "Embedding", code: -6, userInfo: [NSLocalizedDescriptionKey: "Input too large for pipe communication (\(inputString.count) chars). Text splitting should have prevented this."])
        }
        
        print("[PersistentEmbeddingService] Sending batch of \(validatedTexts.count) texts, input size: \(inputString.count) chars")
        if validatedTexts.count == 1 {
            print("[PersistentEmbeddingService] Single text preview: \(String(validatedTexts[0].prefix(100)))...")
        }
        
        // Write to input pipe
        inputPipe.fileHandleForWriting.write(inputString.data(using: .utf8)!)
        
        // Wait for response with length-header protocol (with fallback to old method)
        let timeout = 180.0 // Increased timeout to 180 seconds for very large files
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
            
            // First, read the length header (4 bytes, big-endian)
            if !headerRead && !fallbackMode && outputData.count >= 4 {
                let headerData = outputData.prefix(4)
                let lengthBytes = [UInt8](headerData)
                
                print("[PersistentEmbeddingService] DEBUG: Raw header bytes: \(lengthBytes)")
                print("[PersistentEmbeddingService] DEBUG: Raw data preview: \(String(data: outputData.prefix(50), encoding: .utf8) ?? "Invalid UTF-8")")
                
                // Check if this looks like a length header (reasonable values)
                let calculatedLength = Int(lengthBytes[0]) << 24 | Int(lengthBytes[1]) << 16 | Int(lengthBytes[2]) << 8 | Int(lengthBytes[3])
                
                print("[PersistentEmbeddingService] DEBUG: Calculated length: \(calculatedLength)")
                
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
                        print("[PersistentEmbeddingService] DEBUG: Raw data that caused fallback: \(String(data: outputData.prefix(100), encoding: .utf8) ?? "Invalid UTF-8")")
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
            
            Thread.sleep(forTimeInterval: 0.05) // Reduced sleep time for more responsive reading
        }
        
        guard !outputData.isEmpty else {
            throw NSError(domain: "Embedding", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response from embedding process"])
        }
        
        // Try to parse the JSON response
        print("[PersistentEmbeddingService] Attempting to parse JSON response (\(outputData.count) bytes)")
        let result: Any
        do {
            print("[PersistentEmbeddingService] DEBUG: About to parse JSON with \(outputData.count) bytes")
            print("[PersistentEmbeddingService] DEBUG: Raw data preview: \(String(data: outputData.prefix(200), encoding: .utf8) ?? "Invalid UTF-8")")
            
            result = try JSONSerialization.jsonObject(with: outputData)
            print("[PersistentEmbeddingService] ✅ JSON parsing successful")
            print("[PersistentEmbeddingService] DEBUG: Parsed JSON type: \(type(of: result))")
        } catch {
            print("[PersistentEmbeddingService] JSON parsing failed: \(error)")
            print("[PersistentEmbeddingService] Raw response length: \(outputData.count)")
            
            // Log the first and last 100 characters for debugging
            if let debugString = String(data: outputData, encoding: .utf8) {
                let first100 = String(debugString.prefix(100))
                let last100 = String(debugString.suffix(100))
                print("[PersistentEmbeddingService] Response start: \(first100)")
                print("[PersistentEmbeddingService] Response end: \(last100)")
                print("[PersistentEmbeddingService] DEBUG: Full raw data: \(debugString)")
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

