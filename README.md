# Smart Light Swift 🧠✨

A powerful **Retrieval-Augmented Generation (RAG)** application built with SwiftUI that combines local embeddings with cloud AI to provide intelligent document search and question-answering capabilities.

## 🌟 Features

### 🤖 **Hybrid AI Architecture**
- **Local Embeddings**: Google EmbeddingGemma-300m running locally via Python subprocess
- **Cloud LLM**: OpenAI GPT-5 Nano for intelligent responses
- **Cost Optimization**: Only uses expensive cloud AI for final responses, keeping document processing local

### 📚 **Document Intelligence**
- **Multi-Format Support**: PDF, DOCX, PPTX, TXT, Markdown, HTML, CSV, JSON, YAML, Excel files
- **Code Files**: Python, JavaScript, TypeScript, Java, Go, C++, C#, PHP, SQL, Shell scripts
- **Smart Chunking**: Intelligent text segmentation with 2000-character chunks and natural boundaries
- **Vector Search**: Cosine similarity search with 768-dimensional embeddings

### 💬 **Intelligent Chat Interface**
- **Context-Aware Responses**: Answers questions using your indexed documents
- **Automatic Citations**: Sources are automatically attributed with clickable references
- **General Knowledge**: Falls back to general AI responses when no relevant documents found
- **Session Management**: Maintains conversation history
- **Loading States**: Visual feedback during processing

### 🔧 **Advanced Configuration**
- **Environment Variables**: Secure API key management via `.env` files
- **Folder Indexing**: Recursive folder scanning with progress tracking
- **Settings UI**: Native macOS settings window with real-time status
- **Error Handling**: Graceful failure recovery and user feedback

## 🏗️ Architecture

### **Data Flow**
```
User Input → Text Chunking → Local Embeddings → Vector Storage → Similarity Search → AI Response
```

### **Components**
- **`RagEngine`**: Core RAG logic and AI orchestration
- **`LocalEmbeddingService`**: Python subprocess for Gemma embeddings
- **`InMemoryVectorStore`**: High-performance vector similarity search
- **`Indexer`**: Document processing and chunking
- **`OpenAIService`**: GPT-5 Nano integration
- **`ChatView`**: SwiftUI chat interface

### **Storage**
- **In-Memory Vector Store**: 768-dimensional embeddings with cosine similarity
- **Document Chunks**: Up to 200 chunks per file, 2000 characters each
- **Session-Based**: Data persists during app session only

## 🚀 Getting Started

### **Prerequisites**
- macOS 13.0+
- Xcode 15.0+
- Python 3.12+ with virtual environment
- OpenAI API key (optional, for AI responses)

### **Installation**

1. **Clone the repository**
   ```bash
   git clone https://github.com/STV1222/Smart_light_swift.git
   cd Smart_light_swift
   ```

2. **Set up Python environment**
   ```bash
   # Create virtual environment
   python3 -m venv .venv
   source .venv/bin/activate
   
   # Install dependencies
   pip install sentence-transformers torch
   ```

3. **Configure environment variables**
   ```bash
   # Create .env file in project root or ~/.smartlight/
   echo "OPENAI_API_KEY=your_openai_api_key_here" > ~/.smartlight/.env
   echo "HF_TOKEN=your_huggingface_token_here" >> ~/.smartlight/.env
   ```

4. **Open in Xcode**
   ```bash
   open "Smart Light-Swift.xcodeproj"
   ```

5. **Build and run** the application

### **First Use**

1. **Open Settings** (⌘+, or click the gear icon)
2. **Index Folders**: Click "Index folders…" and select directories containing your documents
3. **Start Chatting**: Ask questions about your indexed documents

## 📖 Usage

### **Indexing Documents**
- Click the **Settings** button (⚙️) in the chat interface
- Select **"Index folders…"** to choose directories
- Monitor progress with the built-in progress bar and stage indicators
- View indexed file count and folder list

### **Asking Questions**
- **Document Questions**: "What does this code do?", "Summarize the PDF content"
- **File Discovery**: "List files", "What files are in my folder?"
- **General Questions**: Works without indexed documents (requires OpenAI API key)

### **Understanding Responses**
- **Citations**: Look for `[1], [2]` references in responses
- **Sources**: Clickable source links at the bottom of responses
- **Confidence**: Low-confidence responses indicate limited relevant content

## 🔐 Configuration

### **Environment Variables**
Place these in `~/.smartlight/.env` or project root `.env`:

```bash
# Required for AI responses
OPENAI_API_KEY=sk-your-openai-api-key

# Optional: For Hugging Face models
HF_TOKEN=your-huggingface-token

# Optional: Embedding configuration
EMBEDDING_BACKEND=gemma
LOCAL_EMBEDDING_MODEL=google/embeddinggemma-300m
```

### **Supported File Types**

| Category | Extensions |
|----------|------------|
| **Documents** | `.pdf`, `.docx`, `.pptx`, `.rtf`, `.txt`, `.md`, `.html` |
| **Data** | `.csv`, `.tsv`, `.json`, `.yaml`, `.yml`, `.xlsx`, `.xls` |
| **Code** | `.py`, `.js`, `.ts`, `.tsx`, `.jsx`, `.java`, `.go`, `.rb`, `.rs`, `.cpp`, `.c`, `.h`, `.cs`, `.php`, `.sh`, `.sql` |
| **Other** | `.log`, `.tex`, `.ini`, `.toml` |

## 🎯 Token Usage & Costs

### **Local Processing (Free)**
- **Document Indexing**: EmbeddingGemma-300m runs locally
- **Vector Search**: In-memory cosine similarity
- **Text Processing**: Local chunking and extraction

### **Cloud Processing (Paid)**
- **GPT-5 Nano**: Only for final responses
- **Typical Cost**: $0.01-0.15 per query
- **Input Tokens**: 1,000-15,000 (context + question)
- **Output Tokens**: Up to 1,000 (response)

### **Cost Optimization**
- Local embeddings reduce API calls
- Smart chunking minimizes context size
- Fallback to context-only responses when no API key

## 🔧 Technical Details

### **Embedding Model**
- **Model**: Google EmbeddingGemma-300m
- **Dimensions**: 768
- **Method**: `encode_document()` for indexing, `encode_query()` for search
- **Runtime**: Python subprocess with sentence-transformers

### **Vector Search**
- **Algorithm**: Cosine similarity with L2 normalization
- **Top-K**: Returns top 20 most similar chunks
- **Confidence**: Threshold of 0.2 for relevance
- **Context**: Uses top 12 chunks for AI responses

### **Chunking Strategy**
- **Max Length**: 2000 characters per chunk
- **Boundaries**: Natural breaks at empty lines
- **Limit**: 200 chunks per file maximum
- **Naming**: `filename.ext#p0`, `filename.ext#p1`, etc.

## 🛠️ Development

### **Project Structure**
```
Smart Light-Swift/
├── Smart Light-Swift/
│   ├── ChatView.swift              # Main chat interface
│   ├── RagEngine.swift             # Core RAG logic
│   ├── Indexer.swift               # Document processing
│   ├── LocalEmbeddingService.swift # Python subprocess
│   ├── OpenAIService.swift         # GPT-5 integration
│   ├── VectorStore.swift           # In-memory storage
│   ├── SettingsView.swift          # Configuration UI
│   ├── PersistentEmbeddingService.swift # Optimized embeddings
│   ├── IncrementalIndexer.swift    # Advanced indexing
│   └── ...
├── Smart Light-Swift.xcodeproj/
└── README.md
```

### **Key Classes**
- **`RagSession`**: Singleton managing all RAG components
- **`ChatViewModel`**: Observable object for chat state
- **`InMemoryVectorStore`**: Vector similarity search
- **`DocumentChunk`**: Individual document segments

### **Dependencies**
- **SwiftUI**: Native macOS interface
- **Foundation**: Core functionality
- **PDFKit**: PDF text extraction
- **Python**: Embedding generation (subprocess)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **Google**: EmbeddingGemma-300m model
- **OpenAI**: GPT-5 Nano API
- **Hugging Face**: Sentence Transformers library
- **Apple**: SwiftUI framework

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/STV1222/Smart_light_swift/issues)
- **Discussions**: [GitHub Discussions](https://github.com/STV1222/Smart_light_swift/discussions)

---

**Built with ❤️ using SwiftUI and the power of local AI**