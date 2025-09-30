import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

final class Indexer {
    private let embedder: EmbeddingService
    private let store: InMemoryVectorStore
    private(set) var indexedFolders: [String] = []

    init(embedder: EmbeddingService, store: InMemoryVectorStore) {
        self.embedder = embedder
        self.store = store
    }

    func index(folders: [String], progress: ((Double) -> Void)? = nil, shouldCancel: (() -> Bool)? = nil) throws {
        self.indexedFolders = folders
        let fm = FileManager.default
        var files: [String] = []
        
        // Supported file extensions like Python version
        let supportedExts: Set<String> = [
            ".pdf", ".docx", ".pptx", ".rtf", ".txt", ".md", ".markdown", ".html", ".htm",
            ".csv", ".tsv", ".log", ".tex", ".json", ".yaml", ".yml", ".toml", ".ini",
            ".xlsx", ".xlsm", ".xls",
            ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".go", ".rb", ".rs",
            ".cpp", ".cc", ".c", ".h", ".hpp", ".cs", ".php", ".sh", ".sql"
        ]
        
        for folder in folders {
            let en = fm.enumerator(atPath: folder)
            while let rel = (en?.nextObject() as? String) {
                let path = (folder as NSString).appendingPathComponent(rel)
                let ext = (rel as NSString).pathExtension.lowercased()
                if supportedExts.contains(".\(ext)") && !shouldExcludeFile(path: path) {
                    files.append(path)
                } else if shouldExcludeFile(path: path) {
                    print("[Indexer] Excluding file: \(path)")
                }
            }
        }
        
        let total = max(1, files.count)
        var done = 0
        print("[Indexer] Starting to process \(files.count) files")
        for f in files {
            // Check for cancellation before processing each file
            if let shouldCancel = shouldCancel, shouldCancel() {
                print("[Indexer] Indexing cancelled by user")
                throw NSError(domain: "Indexer", code: -999, userInfo: [NSLocalizedDescriptionKey: "Indexing cancelled by user"])
            }
            
            do {
                print("[Indexer] Processing file \(done + 1)/\(total): \(f)")
                let text = try extractText(path: f)
                let chunks = chunk(text: text, path: f)
                print("[Indexer] Extracted \(chunks.count) chunks from \(f)")
                
                // Check for cancellation before embedding
                if let shouldCancel = shouldCancel, shouldCancel() {
                    print("[Indexer] Indexing cancelled by user before embedding")
                    throw NSError(domain: "Indexer", code: -999, userInfo: [NSLocalizedDescriptionKey: "Indexing cancelled by user"])
                }
                
                let embs = try embedder.embed(texts: chunks, asQuery: false, progress: nil)
                print("[Indexer] Generated \(embs.count) embeddings for \(f)")
                for (i, e) in embs.enumerated() { 
                    let chunkPath = f + "#p\(i)"
                    store.add(path: chunkPath, text: chunks[i], embedding: e) 
                    print("[Indexer] Added chunk \(i): \(chunkPath) - \(String(chunks[i].prefix(50)))...")
                }
                print("[Indexer] Added \(chunks.count) chunks to store. Total store count: \(store.count)")
            } catch {
                print("[Indexer] Failed to process file \(f): \(error)")
                if let nsError = error as NSError?, nsError.code == -7 {
                    print("[Indexer] Embedding timeout for file \(f), skipping...")
                } else if let nsError = error as NSError?, nsError.code == -6 {
                    print("[Indexer] Embedding timeout for file \(f), skipping...")
                } else if let nsError = error as NSError?, nsError.code == -999 {
                    // Re-throw cancellation errors
                    throw error
                }
                // Continue with other files for other errors
            }
            done += 1
            progress?(Double(done)/Double(total))
        }
        print("[Indexer] Completed processing. Total chunks in store: \(store.count)")
    }

    private func extractText(path: String) throws -> String {
        if path.hasSuffix(".txt") || path.hasSuffix(".md") {
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        if path.hasSuffix(".pdf") {
            #if canImport(PDFKit)
            if let pdf = PDFDocument(url: URL(fileURLWithPath: path)) {
                var out = ""
                for i in 0..<pdf.pageCount { out += pdf.page(at: i)?.string ?? ""; out += "\n" }
                if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return out }
            }
            #endif
        }
        // Fallback to filename as content when rich extractors are not available
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func chunk(text: String, path: String) -> [String] {
        // More sophisticated chunking like Python version
        let lines = text.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentChunk = ""
        var currentLength = 0
        let maxChunkLength = 2000 // Reasonable chunk size
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else {
                // Empty line - end current chunk if it has content
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                    currentChunk = ""
                    currentLength = 0
                }
                continue
            }
            
            // Check if adding this line would exceed max length
            if currentLength + trimmedLine.count > maxChunkLength && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                currentChunk = trimmedLine
                currentLength = trimmedLine.count
            } else {
                if !currentChunk.isEmpty {
                    currentChunk += "\n" + trimmedLine
                } else {
                    currentChunk = trimmedLine
                }
                currentLength = currentChunk.count
            }
        }
        
        // Add final chunk if it has content
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        // Limit number of chunks per file (like Python version)
        return Array(chunks.prefix(200))
    }
    
    // MARK: - Smart File Filtering
    
    private func shouldExcludeFile(path: String) -> Bool {
        let fileName = (path as NSString).lastPathComponent
        
        // Exclude hidden files and directories
        if fileName.hasPrefix(".") {
            return true
        }
        
        // Exclude any path containing virtual environment directories
        if path.contains("/.venv") || path.contains("/venv") || path.contains("\\.venv") || path.contains("\\venv") {
            return true
        }
        
        // Exclude any path containing Python package directories
        if path.contains("/site-packages/") || path.contains("\\site-packages\\") {
            return true
        }
        
        // Exclude any path containing node_modules
        if path.contains("/node_modules/") || path.contains("\\node_modules\\") {
            return true
        }
        
        // Exclude iOS/mobile dependency directories
        if path.contains("/Pods/") || path.contains("\\Pods\\") {
            return true
        }
        
        // Exclude other mobile dependency directories
        if path.contains("/android/") || path.contains("\\android\\") || path.contains("/ios/") || path.contains("\\ios\\") {
            return true
        }
        
        // Exclude common dependency patterns (concise version)
        let commonDependencyPatterns = [
            "/vendor/", "/bower_components/", "/jspm_packages/", "/packages/",
            "/external/", "/third_party/", "/third-party/", "/dependencies/", "/deps/",
            "/libs/", "/libraries/", "/frameworks/", "/plugins/", "/extensions/",
            "/assets/", "/static/", "/public/", "/resources/", "/media/", "/images/",
            "/css/", "/js/", "/fonts/", "/docs/", "/documentation/", "/examples/",
            "/tests/", "/test/", "/spec/", "/fixtures/", "/mocks/", "/stubs/",
            "/cypress/", "/playwright/", "/jest/", "/mocha/", "/karma/", "/storybook/",
            "/.docker/", "/.terraform/", "/.kubernetes/", "/.firebase/", "/.aws/"
        ]
        
        for pattern in commonDependencyPatterns {
            if path.contains(pattern) || path.contains(pattern.replacingOccurrences(of: "/", with: "\\")) {
                return true
            }
        }
        
        // Exclude any path containing .git
        if path.contains("/.git/") || path.contains("\\.git\\") {
            return true
        }
        
        // Exclude any path containing build directories
        if path.contains("/build/") || path.contains("\\build\\") || path.contains("/dist/") || path.contains("\\dist\\") {
            return true
        }
        
        // Exclude Next.js build artifacts
        if path.contains("/.next/") || path.contains("\\.next\\") {
            return true
        }
        
        // Exclude webpack hot-update files
        if fileName.contains("webpack.hot-update") || fileName.contains(".hot-update.") {
            return true
        }
        
        // Exclude other build artifacts
        if path.contains("/out/") || path.contains("\\out\\") || path.contains("/.nuxt/") || path.contains("\\.nuxt\\") {
            return true
        }
        
        // Exclude any path containing cache directories
        if path.contains("/__pycache__/") || path.contains("\\__pycache__\\") || path.contains("/.cache/") || path.contains("\\.cache\\") {
            return true
        }
        
        // Exclude any path containing IDE settings
        if path.contains("/.vscode/") || path.contains("\\.vscode\\") || path.contains("/.idea/") || path.contains("\\.idea\\") {
            return true
        }
        
        // Exclude any path containing test coverage
        if path.contains("/coverage/") || path.contains("\\coverage\\") || path.contains("/.coverage") || path.contains("\\.coverage") {
            return true
        }
        
        // Exclude any path containing temporary files
        if path.contains("/tmp/") || path.contains("\\tmp\\") || path.contains("/temp/") || path.contains("\\temp\\") {
            return true
        }
        
        // Exclude common third-party library patterns
        if path.contains("/lib/") || path.contains("\\lib\\") || path.contains("/libs/") || path.contains("\\libs\\") {
            return true
        }
        
        // Exclude common third-party library file patterns
        if fileName.hasSuffix(".h") && (fileName.contains("Util") || fileName.contains("Helper") || fileName.contains("Common")) {
            return true
        }
        
        // Exclude Python __init__.py files in library directories
        if fileName == "__init__.py" && (path.contains("/lib/") || path.contains("\\lib\\") || path.contains("/site-packages/") || path.contains("\\site-packages\\")) {
            return true
        }
        
        // Exclude all __init__.py files (they're usually just package markers)
        if fileName == "__init__.py" {
            return true
        }
        
        // Exclude common third-party C/C++ library files
        if fileName.hasSuffix(".h") && (fileName.contains("dtoa") || fileName.contains("util") || fileName.contains("common") || fileName.contains("helper")) {
            return true
        }
        
        // Exclude generic HTML files (loading pages, etc.)
        if fileName == "index.html" && path.contains("Loading") {
            return true
        }
        
        // Exclude files with very generic content
        if fileName == "index.html" && (path.contains("/static/") || path.contains("\\static\\") || path.contains("/public/") || path.contains("\\public\\")) {
            return true
        }
        
        // Exclude specific file patterns
        let excludedFilePatterns = [
            "*.pyc",          // Python compiled files
            "*.pyo",          // Python optimized files
            "*.class",        // Java compiled files
            "*.jar",          // Java archive files
            "*.war",          // Web archive files
            "*.ear",          // Enterprise archive files
            "*.o",            // Object files
            "*.so",           // Shared objects
            "*.dylib",        // Dynamic libraries
            "*.exe",          // Executable files
            "*.dll",          // Dynamic link libraries
            "*.bin",          // Binary files
            "*.log",          // Log files (unless specifically needed)
            "*.tmp",          // Temporary files
            "*.temp",         // Temporary files
            "*.swp",          // Vim swap files
            "*.swo",          // Vim swap files
            "*~",             // Backup files
            "*.bak",          // Backup files
            "*.orig",         // Original files
            "*.rej"           // Rejected files
        ]
        
        // Exclude specific dependency and lock files
        let excludedDependencyFiles = [
            "package-lock.json",
            "yarn.lock",
            "pnpm-lock.yaml",
            "requirements.txt",
            "Pipfile.lock",
            "poetry.lock",
            "composer.lock",
            "Gemfile.lock",
            "Cargo.lock",
            "go.sum",
            "go.mod"
        ]
        
        // Check for dependency files
        if excludedDependencyFiles.contains(fileName) {
            return true
        }
        
        // Check file patterns (simplified pattern matching)
        for pattern in excludedFilePatterns {
            if fileName.contains(pattern) {
                return true
            }
        }
        
        return false
    }
}


