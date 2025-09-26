import Foundation
import Dispatch
#if canImport(PDFKit)
import PDFKit
#endif

// Incremental indexer that only processes changed files
final class IncrementalIndexer {
    private let embedder: EmbeddingService
    private let store: InMemoryVectorStore
    private(set) var indexedFolders: [String] = []
    
    // File modification tracking
    private var fileModificationTimes: [String: Date] = [:]
    private let modificationTimesFile: URL
    private let modificationQueue = DispatchQueue(label: "modification.tracking", qos: .userInitiated)
    
    // Parallel processing
    private let maxConcurrentFiles = ProcessInfo.processInfo.processorCount
    private let fileProcessingQueue = DispatchQueue(label: "file.processing", qos: .userInitiated, attributes: .concurrent)
    private let embeddingQueue = DispatchQueue(label: "embedding.processing", qos: .userInitiated, attributes: .concurrent)
    private let storeQueue = DispatchQueue(label: "store.access", qos: .userInitiated)
    
    // Batch processing
    private let maxBatchSize = 50
    
    init(embedder: EmbeddingService, store: InMemoryVectorStore) {
        self.embedder = embedder
        self.store = store
        
        // Set up modification times file
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.modificationTimesFile = documentsPath.appendingPathComponent("SmartLightFileModifications.json")
        
        // Load existing modification times
        loadModificationTimes()
    }
    
    func index(folders: [String], progress: ((Double) -> Void)? = nil, shouldCancel: (() -> Bool)? = nil) throws {
        self.indexedFolders = folders
        let fm = FileManager.default
        
        // Check if this is a new folder selection (different from previously indexed folders)
        let isNewFolderSelection = !areFoldersSameAsPrevious(folders)
        
        // Check if we need to force re-indexing due to low chunk count (only once)
        let shouldForceReindex = shouldForceReindexing()
        
        // Collect all files and check for modifications
        var filesToProcess: [String] = []
        var totalFiles = 0
        
        for folder in folders {
            let en = fm.enumerator(atPath: folder)
            while let rel = (en?.nextObject() as? String) {
                let path = (folder as NSString).appendingPathComponent(rel)
                let ext = (rel as NSString).pathExtension.lowercased()
                
                if isSupportedFile(ext: ext) {
                    totalFiles += 1
                    
                    // If this is a new folder selection OR force re-indexing, process ALL files
                    // Otherwise, use incremental logic
                    if isNewFolderSelection || shouldForceReindex || shouldProcessFile(path: path) {
                        filesToProcess.append(path)
                    }
                }
            }
        }
        
        if isNewFolderSelection {
            print("[IncrementalIndexer] NEW FOLDER SELECTION - Processing ALL \(totalFiles) files with full indexing")
        } else if shouldForceReindex {
            print("[IncrementalIndexer] FORCE RE-INDEXING - Processing ALL \(totalFiles) files due to low chunk count")
        } else {
            print("[IncrementalIndexer] Found \(totalFiles) total files, \(filesToProcess.count) need processing")
        }
        
        if filesToProcess.isEmpty {
            print("[IncrementalIndexer] No files need processing - all up to date")
            progress?(1.0)
            return
        }
        
        // Process files in parallel batches
        let batches = filesToProcess.chunked(into: maxBatchSize)
        let totalBatches = batches.count
        
        print("[IncrementalIndexer] Processing \(filesToProcess.count) files in \(totalBatches) batches")
        
        // Update progress for file discovery phase (10% of total progress)
        progress?(0.1)
        
        // Clear modification times to force full re-indexing with new chunking strategy
        if isNewFolderSelection {
            print("[IncrementalIndexer] NEW FOLDER SELECTION - Clearing store and modification times for fresh start")
            store.reset() // Clear the store for new folder
        } else if shouldForceReindex {
            print("[IncrementalIndexer] FORCE RE-INDEXING - Clearing modification times for fresh start")
        } else {
            print("[IncrementalIndexer] Clearing modification times to force full re-indexing")
        }
        fileModificationTimes.removeAll()
        
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: maxConcurrentFiles)
        var processedBatches = 0
        let progressLock = NSLock()
        
        for (batchIndex, batch) in batches.enumerated() {
            if let shouldCancel = shouldCancel, shouldCancel() {
                print("[IncrementalIndexer] Indexing cancelled by user")
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
                    try self.processBatch(batch, batchIndex: batchIndex, totalBatches: totalBatches, progress: progress)
                    
                    progressLock.lock()
                    processedBatches += 1
                    print("[IncrementalIndexer] Completed batch \(processedBatches)/\(totalBatches)")
                    progressLock.unlock()
                    
                } catch {
                    print("[IncrementalIndexer] Batch \(batchIndex) failed: \(error)")
                }
            }
        }
        
        group.wait()
        
        // Update progress for finalization phase (80% to 90%)
        progress?(0.8)
        
        // Save modification times
        saveModificationTimes()
        
        // Update progress for completion phase (90% to 100%)
        progress?(0.9)
        
        // Force a synchronous read of the store count
        let finalCount = storeQueue.sync { store.count }
        print("[IncrementalIndexer] Completed incremental processing. Total chunks in store: \(finalCount)")
        
        // Final progress update
        progress?(1.0)
    }
    
    private func isSupportedFile(ext: String) -> Bool {
        let supportedExts: Set<String> = [
            // Documents
            ".pdf", ".docx", ".doc", ".pptx", ".ppt", ".rtf", ".txt", ".md", ".markdown", 
            ".html", ".htm", ".xml", ".tex",
            
            // Spreadsheets
            ".xlsx", ".xlsm", ".xls", ".csv", ".tsv",
            
            // Code files
            ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".go", ".rb", ".rs", ".cpp", ".cc", ".c", ".h", ".hpp", 
            ".cs", ".php", ".swift", ".kt", ".scala", ".r", ".m", ".mm", ".sh", ".bash", ".zsh", ".sql",
            
            // Web & Markup
            ".css", ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf",
            
            // Data & Logs
            ".log", ".out", ".err"
        ]
        return supportedExts.contains(".\(ext)")
    }
    
    private func shouldProcessFile(path: String) -> Bool {
        return modificationQueue.sync {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard let modificationDate = attributes[.modificationDate] as? Date else {
                    return true // Process if we can't get modification date
                }
                
                let lastKnownModification = fileModificationTimes[path]
                
                if let lastKnown = lastKnownModification {
                    return modificationDate > lastKnown
                } else {
                    return true // Process if we haven't seen this file before
                }
            } catch {
                return true // Process if we can't get file attributes
            }
        }
    }
    
    private func processBatch(_ files: [String], batchIndex: Int, totalBatches: Int, progress: ((Double) -> Void)? = nil) throws {
        print("[IncrementalIndexer] Processing batch \(batchIndex + 1)/\(totalBatches) with \(files.count) files")
        
        // Extract text from all files in parallel
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: maxConcurrentFiles)
        var fileContents: [(path: String, chunks: [String])] = []
        let contentsLock = NSLock()
        var processedFiles = 0
        let fileProgressLock = NSLock()
        var lastProgressUpdate = Date()
        
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
                    print("[IncrementalIndexer] Extracted \(chunks.count) chunks from \(file) (text length: \(text.count) chars)")
                    
                    contentsLock.lock()
                    fileContents.append((path: file, chunks: chunks))
                    contentsLock.unlock()
                    
                    // Update modification time
                    self.updateModificationTime(for: file)
                    
                    // Update progress within batch (throttled to avoid overwhelming UI)
                    fileProgressLock.lock()
                    processedFiles += 1
                    let now = Date()
                    let shouldUpdate = now.timeIntervalSince(lastProgressUpdate) > 0.5 // Update every 500ms max
                    
                    if shouldUpdate {
                        let fileProgress = Double(processedFiles) / Double(files.count)
                        let batchProgress = Double(batchIndex) / Double(totalBatches)
                        // Progress during file processing: 10% + (batch progress + 0.1 * file progress) * 0.3
                        // This gives us 10% + 0.3 = 13% max for file processing phase
                        let overallProgress = 0.1 + (batchProgress + 0.1 * fileProgress / Double(totalBatches)) * 0.3
                        print("[IncrementalIndexer] File progress: \(processedFiles)/\(files.count) in batch \(batchIndex + 1)/\(totalBatches) = \(Int(overallProgress * 100))%")
                        progress?(overallProgress)
                        lastProgressUpdate = now
                    }
                    fileProgressLock.unlock()
                    
                } catch {
                    print("[IncrementalIndexer] Failed to extract text from \(file): \(error)")
                }
            }
        }
        
        group.wait()
        
        // File processing complete - progress will be updated during embedding phase
        
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
            print("[IncrementalIndexer] No chunks to embed in batch \(batchIndex)")
            return
        }
        
        print("[IncrementalIndexer] Embedding \(allChunks.count) chunks from batch \(batchIndex)")
        
        // Update progress for embedding phase start
        let batchProgress = Double(batchIndex) / Double(totalBatches)
        let embeddingStartProgress = 0.1 + (batchProgress + 0.1 / Double(totalBatches)) * 0.7
        print("[IncrementalIndexer] Starting embedding for batch \(batchIndex + 1)/\(totalBatches): \(Int(embeddingStartProgress * 100))%")
        progress?(embeddingStartProgress)
        
        // Embed all chunks in one batch with progress tracking
        let embeddings = try embedder.embed(texts: allChunks, asQuery: false) { embeddingProgress in
            // Convert embedding progress (0-1) to overall progress (10% to 80%)
            let batchProgress = Double(batchIndex) / Double(totalBatches)
            let overallProgress = 0.1 + (batchProgress + embeddingProgress / Double(totalBatches)) * 0.7
            print("[IncrementalIndexer] Embedding progress: \(Int(embeddingProgress * 100))% for batch \(batchIndex + 1)/\(totalBatches) = \(Int(overallProgress * 100))%")
            progress?(overallProgress)
        }
        
        // Add to store synchronously to ensure it's completed before returning
        storeQueue.sync {
            print("[IncrementalIndexer] Adding chunks to store object: \(ObjectIdentifier(store))")
            for (i, embedding) in embeddings.enumerated() {
                let chunkPath = chunkPaths[i]
                let chunkText = allChunks[i]
                self.store.add(path: chunkPath, text: chunkText, embedding: embedding)
            }
            print("[IncrementalIndexer] Added \(embeddings.count) chunks to store from batch \(batchIndex)")
        }
        
        // Final progress update for this batch (100% of batch progress)
        let finalBatchProgress = Double(batchIndex + 1) / Double(totalBatches)
        let finalProgress = 0.1 + (finalBatchProgress * 0.7)
        print("[IncrementalIndexer] Batch \(batchIndex + 1)/\(totalBatches) complete: \(Int(finalProgress * 100))%")
        progress?(finalProgress)
        
        // Update modification times for all processed files (outside the sync block)
        for filePath in files {
            self.updateModificationTime(for: filePath)
        }
    }
    
    private func updateModificationTime(for path: String) {
        modificationQueue.async {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                if let modificationDate = attributes[.modificationDate] as? Date {
                    self.fileModificationTimes[path] = modificationDate
                }
            } catch {
                print("[IncrementalIndexer] Failed to get modification time for \(path): \(error)")
            }
        }
    }
    
    private func loadModificationTimes() {
        modificationQueue.async {
            do {
                let data = try Data(contentsOf: self.modificationTimesFile)
                if let times = try JSONSerialization.jsonObject(with: data) as? [String: TimeInterval] {
                    self.fileModificationTimes = times.mapValues { Date(timeIntervalSince1970: $0) }
                    print("[IncrementalIndexer] Loaded \(self.fileModificationTimes.count) file modification times")
                }
            } catch {
                // This is expected on first run - file doesn't exist yet
                if (error as NSError).code == 260 { // File not found
                    print("[IncrementalIndexer] No previous modification times found (first run)")
                } else {
                    print("[IncrementalIndexer] Failed to load modification times: \(error)")
                }
            }
        }
    }
    
    private func saveModificationTimes() {
        modificationQueue.async {
            do {
                let times = self.fileModificationTimes.mapValues { $0.timeIntervalSince1970 }
                let data = try JSONSerialization.data(withJSONObject: times)
                try data.write(to: self.modificationTimesFile)
                print("[IncrementalIndexer] Saved \(times.count) file modification times")
            } catch {
                print("[IncrementalIndexer] Failed to save modification times: \(error)")
            }
        }
    }
    
    private func extractText(path: String) throws -> String {
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        
        // Text files - direct reading
        if fileExtension == "txt" || fileExtension == "md" || fileExtension == "markdown" {
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        
        // LaTeX files - extract readable content
        if fileExtension == "tex" {
            do {
                let rawContent = try String(contentsOfFile: path, encoding: .utf8)
                return extractLatexContent(rawContent)
            } catch {
                print("[IncrementalIndexer] Failed to read LaTeX file \(path): \(error)")
                return URL(fileURLWithPath: path).lastPathComponent
            }
        }
        
        // Code files - direct reading
        if ["py", "js", "ts", "tsx", "jsx", "java", "cpp", "cc", "c", "h", "hpp", "cs", "php", "rb", "rs", "go", "swift", "kt", "scala", "r", "m", "mm", "sh", "bash", "zsh", "sql", "html", "css", "xml", "json", "yaml", "yml", "toml", "ini", "cfg", "conf"].contains(fileExtension) {
            do {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                if !content.isEmpty {
                    return content
                }
            } catch {
                print("[IncrementalIndexer] Failed to read \(fileExtension) file \(path): \(error)")
            }
        }
        
        // CSV files - direct reading
        if fileExtension == "csv" || fileExtension == "tsv" {
            do {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                if !content.isEmpty {
                    return content
                }
            } catch {
                print("[IncrementalIndexer] Failed to read CSV file \(path): \(error)")
            }
        }
        
        // PDF files
        if fileExtension == "pdf" {
            #if canImport(PDFKit)
            if let pdf = PDFDocument(url: URL(fileURLWithPath: path)) {
                var out = ""
                for i in 0..<pdf.pageCount { out += pdf.page(at: i)?.string ?? ""; out += "\n" }
                if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return out }
            }
            #endif
        }
        
        // Office documents - use Python extraction
        if ["docx", "doc", "pptx", "ppt", "xlsx", "xls"].contains(fileExtension) {
            do {
                let extractedText = try extractOfficeDocumentText(path: path, fileExtension: fileExtension)
                if !extractedText.isEmpty {
                    return extractedText
                }
            } catch {
                print("[IncrementalIndexer] Failed to extract text from \(fileExtension) file \(path): \(error)")
            }
            
            // Fallback: return filename with indication
            return "\(fileExtension.uppercased()) FILE: \(fileName) - Content extraction failed"
        }
        
        // RTF files
        if fileExtension == "rtf" {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let content = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                let text = content.string
                if !text.isEmpty {
                    return text
                }
            } catch {
                print("[IncrementalIndexer] Failed to read RTF file \(path): \(error)")
            }
        }
        
        // Log files
        if fileExtension == "log" {
            do {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                if !content.isEmpty {
                    return content
                }
            } catch {
                print("[IncrementalIndexer] Failed to read log file \(path): \(error)")
            }
        }
        
        // Fallback: return filename
        print("[IncrementalIndexer] Unsupported file type: \(fileExtension) for file: \(path)")
        return fileName
    }
    
    private func extractOfficeDocumentText(path: String, fileExtension: String) throws -> String {
        let process = Process()
        
        // Use the project's Python environment
        let projectRoot = "/Users/stv/Desktop/Business/Smart light"
        let venvPython = "\(projectRoot)/.venv/bin/python3"
        
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            process.executableURL = URL(fileURLWithPath: venvPython)
            print("[IncrementalIndexer] Using virtual environment Python: \(venvPython)")
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"]
            print("[IncrementalIndexer] Using system Python (venv not found at: \(venvPython))")
        }
        
        // Create comprehensive Python script to extract text from all Office document types
        let script = """
import sys
import os
import zipfile
import xml.etree.ElementTree as ET

def extract_docx_text(file_path):
    try:
        from docx import Document
        doc = Document(file_path)
        text = []
        for paragraph in doc.paragraphs:
            if paragraph.text.strip():
                text.append(paragraph.text.strip())
        return '\\n'.join(text)
    except ImportError:
        # Fallback: extract using zipfile
        with zipfile.ZipFile(file_path, 'r') as docx:
            xml_content = docx.read('word/document.xml')
            root = ET.fromstring(xml_content)
            text_content = []
            for elem in root.iter():
                if elem.text and elem.text.strip():
                    text_content.append(elem.text.strip())
            return ' '.join(text_content)

def extract_pptx_text(file_path):
    try:
        from pptx import Presentation
        prs = Presentation(file_path)
        text = []
        for slide in prs.slides:
            for shape in slide.shapes:
                if hasattr(shape, "text") and shape.text.strip():
                    text.append(shape.text.strip())
        return '\\n'.join(text)
    except ImportError:
        # Fallback: extract using zipfile
        with zipfile.ZipFile(file_path, 'r') as pptx:
            text_content = []
            # Get all slide XML files
            slide_files = [f for f in pptx.namelist() if f.startswith('ppt/slides/slide') and f.endswith('.xml')]
            for slide_file in slide_files:
                xml_content = pptx.read(slide_file)
                root = ET.fromstring(xml_content)
                for elem in root.iter():
                    if elem.text and elem.text.strip():
                        text_content.append(elem.text.strip())
            return ' '.join(text_content)

def extract_xlsx_text(file_path):
    try:
        import pandas as pd
        # Read all sheets
        excel_file = pd.ExcelFile(file_path)
        text_content = []
        for sheet_name in excel_file.sheet_names:
            df = pd.read_excel(file_path, sheet_name=sheet_name)
            # Convert dataframe to text
            sheet_text = df.to_string(index=False, header=True)
            if sheet_text.strip():
                text_content.append(f"Sheet: {sheet_name}\\n{sheet_text}")
        return '\\n\\n'.join(text_content)
    except ImportError:
        # Fallback: extract using zipfile (xlsx is a zip file)
        with zipfile.ZipFile(file_path, 'r') as xlsx:
            text_content = []
            # Read shared strings
            try:
                shared_strings_xml = xlsx.read('xl/sharedStrings.xml')
                shared_root = ET.fromstring(shared_strings_xml)
                shared_strings = []
                for si in shared_root.findall('.//{http://schemas.openxmlformats.org/spreadsheetml/2006/main}si'):
                    text_elem = si.find('.//{http://schemas.openxmlformats.org/spreadsheetml/2006/main}t')
                    if text_elem is not None and text_elem.text:
                        shared_strings.append(text_elem.text.strip())
                
                # Read worksheet data
                worksheet_files = [f for f in xlsx.namelist() if f.startswith('xl/worksheets/sheet') and f.endswith('.xml')]
                for sheet_file in worksheet_files:
                    xml_content = xlsx.read(sheet_file)
                    root = ET.fromstring(xml_content)
                    for cell in root.findall('.//{http://schemas.openxmlformats.org/spreadsheetml/2006/main}c'):
                        v_elem = cell.find('.//{http://schemas.openxmlformats.org/spreadsheetml/2006/main}v')
                        if v_elem is not None and v_elem.text:
                            try:
                                # Check if it's a shared string reference
                                t_attr = cell.get('t')
                                if t_attr == 's':  # shared string
                                    idx = int(v_elem.text)
                                    if idx < len(shared_strings):
                                        text_content.append(shared_strings[idx])
                                else:  # direct value
                                    text_content.append(v_elem.text.strip())
                            except (ValueError, IndexError):
                                continue
            except Exception:
                pass
            return ' '.join(text_content)

def extract_old_format_text(file_path, file_type):
    # For old .doc, .ppt, .xls files - basic extraction attempt
    try:
        if file_type == 'doc':
            # Try to read as text (very basic)
            with open(file_path, 'rb') as f:
                content = f.read()
                # Extract readable text (this is very basic)
                text = ''.join(chr(b) for b in content if 32 <= b <= 126)
                return text[:5000]  # Limit to avoid too much noise
        elif file_type == 'ppt':
            # PowerPoint old format - very limited extraction
            with open(file_path, 'rb') as f:
                content = f.read()
                text = ''.join(chr(b) for b in content if 32 <= b <= 126)
                return text[:5000]
        elif file_type == 'xls':
            # Excel old format - very limited extraction
            with open(file_path, 'rb') as f:
                content = f.read()
                text = ''.join(chr(b) for b in content if 32 <= b <= 126)
                return text[:5000]
    except Exception:
        return ""

# Main extraction logic
file_path = '\(path)'
file_ext = '\(fileExtension)'

try:
    if file_ext == 'docx':
        result = extract_docx_text(file_path)
    elif file_ext == 'pptx':
        result = extract_pptx_text(file_path)
    elif file_ext == 'xlsx':
        result = extract_xlsx_text(file_path)
    elif file_ext in ['doc', 'ppt', 'xls']:
        result = extract_old_format_text(file_path, file_ext)
    else:
        result = ""
    
    if result.strip():
        print(result)
    else:
        print(f"FILE: {os.path.basename(file_path)}")
        
except Exception as e:
    print(f"Error extracting text from {file_ext} file: {e}", file=sys.stderr)
    print(f"FILE: {os.path.basename(file_path)}")
    sys.exit(1)
"""
        
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("extract_office_\(UUID().uuidString).py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        
        process.arguments = (process.arguments ?? []) + [scriptURL.path]
        
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        
        // Set up environment - avoid conflicting Python environment variables
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // Remove any conflicting Python environment variables that might cause path issues
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "VIRTUAL_ENV")
        process.environment = env
        
        try process.run()
        process.waitUntilExit()
        
        // Clean up script
        try? FileManager.default.removeItem(at: scriptURL)
        
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            print("[IncrementalIndexer] Python subprocess failed with status \(process.terminationStatus)")
            print("[IncrementalIndexer] Error output: \(errorString)")
            throw NSError(domain: "OfficeExtraction", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to extract \(fileExtension) text: \(errorString)"])
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let extractedText = String(data: data, encoding: .utf8) ?? ""
        
        print("[IncrementalIndexer] Python subprocess output length: \(extractedText.count)")
        print("[IncrementalIndexer] Python subprocess output preview: \(String(extractedText.prefix(200)))...")
        
        let trimmedText = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedText.isEmpty || trimmedText.hasPrefix("FILE:") {
            print("[IncrementalIndexer] No meaningful content extracted from \(fileExtension) file")
        } else {
            print("[IncrementalIndexer] Successfully extracted \(trimmedText.count) characters from \(fileExtension) file")
        }
        
        return trimmedText
    }
    
    private func extractLatexContent(_ rawContent: String) -> String {
        var content = rawContent
        
        // Remove LaTeX comments (lines starting with %)
        let lines = content.components(separatedBy: .newlines)
        let nonCommentLines = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("%") {
                return nil // Skip comment lines
            }
            // Remove inline comments
            if let commentIndex = trimmed.firstIndex(of: "%") {
                return String(trimmed[..<commentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }
        
        content = nonCommentLines.joined(separator: "\n")
        
        // Remove common LaTeX commands and environments
        let latexPatterns = [
            // Document structure
            "\\\\documentclass\\{[^}]*\\}",
            "\\\\usepackage\\{[^}]*\\}",
            "\\\\begin\\{[^}]*\\}",
            "\\\\end\\{[^}]*\\}",
            
            // Formatting commands
            "\\\\[a-zA-Z]+\\{[^}]*\\}",
            "\\\\[a-zA-Z]+\\s*\\[[^\\]]*\\]\\s*\\{[^}]*\\}",
            "\\\\[a-zA-Z]+\\s*\\[[^\\]]*\\]",
            
            // Math environments
            "\\\\\\$\\$.*?\\\\\\$\\$",
            "\\\\\\$.*?\\\\\\$",
            
            // Common commands
            "\\\\title\\{[^}]*\\}",
            "\\\\author\\{[^}]*\\}",
            "\\\\date\\{[^}]*\\}",
            "\\\\section\\{[^}]*\\}",
            "\\\\subsection\\{[^}]*\\}",
            "\\\\subsubsection\\{[^}]*\\}",
            "\\\\paragraph\\{[^}]*\\}",
            "\\\\label\\{[^}]*\\}",
            "\\\\ref\\{[^}]*\\}",
            "\\\\cite\\{[^}]*\\}",
            "\\\\footnote\\{[^}]*\\}",
            "\\\\url\\{[^}]*\\}",
            "\\\\href\\{[^}]*\\}\\{[^}]*\\}",
            
            // Special characters and symbols
            "\\\\[a-zA-Z]+",
            "\\\\[^a-zA-Z\\s]",
            
            // Whitespace cleanup
            "\\s+",
        ]
        
        for pattern in latexPatterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
                let range = NSRange(content.startIndex..<content.endIndex, in: content)
                content = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: " ")
            } catch {
                // If regex fails, continue with next pattern
                continue
            }
        }
        
        // Clean up multiple spaces and newlines
        content = content.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        content = content.replacingOccurrences(of: "\n+", with: "\n", options: .regularExpression)
        
        // Remove empty lines and trim
        let finalLines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        return finalLines.joined(separator: "\n")
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
        // Document-specific chunking with paragraph awareness - maximum coverage
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var currentChunk = ""
        let maxChunkLength = 1000 // Reduced from 2000 to 1000 for more chunks
        
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
        
        // Add overlapping chunks for better coverage
        var overlappingChunks: [String] = []
        for i in 0..<chunks.count {
            overlappingChunks.append(chunks[i])
            // Add overlapping chunk with next paragraph if it exists
            if i + 1 < chunks.count {
                let overlapContent = chunks[i] + "\n\n" + chunks[i + 1]
                overlappingChunks.append(buildChunk(content: overlapContent, fileName: fileName, type: "document-overlap"))
            }
        }
        
        return Array(overlappingChunks.prefix(1000)) // Increased from 500 to 1000
    }
    
    private func chunkCode(text: String, fileName: String) -> [String] {
        // Code-specific chunking with function/class awareness - more inclusive
        let lines = text.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentChunk = ""
        var currentLength = 0
        let maxChunkLength = 900 // Reduced from 1800 to 900 for more chunks
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check for function/class boundaries
            let isFunctionStart = trimmed.hasPrefix("def ") || trimmed.hasPrefix("function ") || 
                                trimmed.hasPrefix("class ") || trimmed.hasPrefix("public ") ||
                                trimmed.hasPrefix("private ") || trimmed.hasPrefix("func ")
            
            if isFunctionStart && !currentChunk.isEmpty && currentLength >= 30 {
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
        // Generic chunking for unknown file types - maximum coverage with sliding window
        let lines = text.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentChunk = ""
        var currentLength = 0
        let maxChunkLength = 750 // Reduced from 1500 to 750 for more chunks
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                if !currentChunk.isEmpty && currentLength >= 30 {
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
        
        // Add sliding window chunks for maximum coverage
        var slidingChunks: [String] = []
        let windowSize = 3 // Create overlapping windows of 3 chunks each
        
        for i in 0..<chunks.count {
            slidingChunks.append(chunks[i])
            
            // Add sliding window chunks
            if i + windowSize <= chunks.count {
                let windowContent = chunks[i..<i + windowSize].joined(separator: "\n")
                slidingChunks.append(buildChunk(content: windowContent, fileName: fileName, type: "generic-window"))
            }
        }
        
        return Array(slidingChunks.prefix(600)) // Increased from 300 to 600
    }
    
    private func buildChunk(content: String, fileName: String, type: String) -> String {
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        **Source:** \(fileName) (\(type))
        **Content:**
        \(cleanContent)
        """
    }
    
    
    private func shouldForceReindexing() -> Bool {
        // Force re-indexing if we have very few chunks (indicating old chunking strategy)
        let currentChunkCount = store.count
        print("[IncrementalIndexer] Current chunk count: \(currentChunkCount)")
        
        // If we have less than 20 chunks, force re-indexing to apply new chunking strategy
        if currentChunkCount < 20 {
            print("[IncrementalIndexer] Forcing re-indexing due to low chunk count (\(currentChunkCount))")
            return true
        }
        
        return false
    }
    
    private func areFoldersSameAsPrevious(_ newFolders: [String]) -> Bool {
        // Compare with previously indexed folders
        let sortedNew = Set(newFolders.map { URL(fileURLWithPath: $0).path })
        let sortedPrevious = Set(indexedFolders.map { URL(fileURLWithPath: $0).path })
        
        let isSame = sortedNew == sortedPrevious
        
        if !isSame {
            print("[IncrementalIndexer] New folder selection detected - will process ALL files")
            print("[IncrementalIndexer] Previous folders: \(sortedPrevious)")
            print("[IncrementalIndexer] New folders: \(sortedNew)")
        } else {
            print("[IncrementalIndexer] Same folder selection - using incremental indexing")
        }
        
        return isSame
    }
}

