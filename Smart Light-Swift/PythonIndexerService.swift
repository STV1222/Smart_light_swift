import Foundation
import Dispatch

// Python-based indexer service that mirrors the working Python project
class PythonIndexerService {
    private var pythonProcess: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    
    var isProcessRunning: Bool {
        return pythonProcess?.isRunning ?? false
    }
    
    init() {
        // Initialize with nil values - will be set up in startProcess
        self.pythonProcess = nil
        self.inputPipe = nil
        self.outputPipe = nil
        self.errorPipe = nil
    }
    
    private func createIndexerScript() -> String {
        return """
        import os
        import sys
        import json
        import time
        import hashlib
        import signal
        
        # Set thread safety environment variables before importing anything else
        os.environ['OMP_NUM_THREADS'] = '1'
        os.environ['OPENBLAS_NUM_THREADS'] = '1'
        os.environ['MKL_NUM_THREADS'] = '1'
        os.environ['NUMEXPR_NUM_THREADS'] = '1'
        os.environ['VECLIB_MAXIMUM_THREADS'] = '1'
        os.environ['NUMBA_NUM_THREADS'] = '1'
        
        # Add debugging output
        print("Python script starting...", file=sys.stderr)
        print("Thread safety environment variables set", file=sys.stderr)
        
        # Add error handling for missing modules
        try:
            import traceback
            print("Traceback imported successfully", file=sys.stderr)
        except ImportError:
            traceback = None
            print("Traceback import failed", file=sys.stderr)
        from dataclasses import dataclass
        from datetime import datetime
        from typing import Iterable, List, Tuple, Optional, Dict

        # External deps
        print("Loading external dependencies...", file=sys.stderr)
        try:
            import faiss
            HAVE_FAISS = True
            print("FAISS imported successfully", file=sys.stderr)
        except Exception as e:
            faiss = None
            HAVE_FAISS = False
            print(f"FAISS import failed: {e}", file=sys.stderr)

        try:
            from sentence_transformers import SentenceTransformer
            HAVE_SENTENCE_TRANSFORMERS = True
            print("SentenceTransformers imported successfully", file=sys.stderr)
        except Exception as e:
            SentenceTransformer = None
            HAVE_SENTENCE_TRANSFORMERS = False
            print(f"SentenceTransformers import failed: {e}", file=sys.stderr)
        
        # Import memory management
        try:
            import gc
            print("Garbage collection imported successfully", file=sys.stderr)
        except Exception as e:
            print(f"Garbage collection import failed: {e}", file=sys.stderr)

        RAG_HOME = os.path.expanduser("~/.smartlight/rag_db")
        FAISS_PATH = os.path.join(RAG_HOME, "faiss.index")
        META_PATH = os.path.join(RAG_HOME, "meta.jsonl")
        MANIFEST_PATH = os.path.join(RAG_HOME, "manifest.json")

        SUPPORTED_EXTS = {
            ".pdf", ".docx", ".pptx", ".rtf", ".txt", ".md", ".markdown", ".html", ".htm",
            ".csv", ".tsv", ".log", ".tex", ".json", ".yaml", ".yml", ".toml", ".ini",
            ".xlsx", ".xlsm", ".xls",
            ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".go", ".rb", ".rs",
            ".cpp", ".cc", ".c", ".h", ".hpp", ".cs", ".php", ".sh", ".sql",
        }

        INDEX_ALL_FILE_TYPES = True

        def ensure_dirs():
            if not os.path.isdir(RAG_HOME):
                os.makedirs(RAG_HOME, exist_ok=True)

        def _load_manifest():
            if not os.path.isfile(MANIFEST_PATH):
                return {}
            try:
                with open(MANIFEST_PATH, "r", encoding="utf-8") as r:
                    return json.load(r)
            except Exception:
                return {}

        def _save_manifest(data):
            try:
                with open(MANIFEST_PATH, "w", encoding="utf-8") as w:
                    json.dump(data, w)
            except Exception:
                pass

        def sha1_of_text(text, path, page):
            normalized = " ".join(text.split())
            h = hashlib.sha1()
            h.update((normalized + "|" + path + "|" + str(page if page is not None else "-")).encode("utf-8", "ignore"))
            return h.hexdigest()

        def load_text_from_file(path):
            print(f"load_text_from_file called for: {path}", file=sys.stderr)
            ext = os.path.splitext(path)[1].lower()
            print(f"File extension in load_text_from_file: {ext}", file=sys.stderr)
            try:
                if ext == ".pdf":
                    print(f"Processing PDF file: {path}", file=sys.stderr)
                    from pypdf import PdfReader
                    print(f"PdfReader imported successfully", file=sys.stderr)
                    reader = PdfReader(path)
                    print(f"PdfReader created for: {path}", file=sys.stderr)
                    pages = []
                    for i, p in enumerate(reader.pages):
                        try:
                            print(f"Processing page {i+1} of PDF", file=sys.stderr)
                            pages.append((i + 1, p.extract_text() or ""))
                        except Exception as e:
                            print(f"Error processing page {i+1}: {e}", file=sys.stderr)
                            pages.append((i + 1, ""))
                    print(f"PDF processing complete, {len(pages)} pages", file=sys.stderr)
                    return ("\\n\\n".join(t for _, t in pages), pages)
                if ext == ".docx":
                    print(f"Processing DOCX file: {path}", file=sys.stderr)
                    # Skip temporary Word files
                    if os.path.basename(path).startswith('~$'):
                        print(f"Skipping temporary Word file: {path}", file=sys.stderr)
                        return ("", None)
                    try:
                        import docx
                        print(f"docx imported successfully", file=sys.stderr)
                        doc = docx.Document(path)
                        print(f"Document opened: {path}", file=sys.stderr)
                        text = "\\n".join(p.text for p in doc.paragraphs)
                        print(f"DOCX processing complete, {len(text)} chars", file=sys.stderr)
                        return (text, None)
                    except Exception as e:
                        print(f"Error processing DOCX file {path}: {e}", file=sys.stderr)
                        return ("", None)
                if ext == ".pptx":
                    from pptx import Presentation
                    prs = Presentation(path)
                    pages = []
                    for i, slide in enumerate(prs.slides):
                        texts = []
                        try:
                            for shape in slide.shapes:
                                if hasattr(shape, "text"):
                                    texts.append(str(shape.text))
                        except Exception:
                            pass
                        pages.append((i + 1, "\\n".join(texts)))
                    return ("\\n\\n".join(t for _, t in pages), pages)
                if ext in {".txt", ".md", ".markdown"}:
                    try:
                        import chardet
                        with open(path, "rb") as f:
                            raw = f.read()
                        enc = chardet.detect(raw).get("encoding") or "utf-8"
                        text = raw.decode(enc, errors="ignore")
                    except Exception:
                        with open(path, "r", encoding="utf-8", errors="ignore") as f:
                            text = f.read()
                    return (text, None)
                if ext in {".html", ".htm"}:
                    try:
                        import chardet
                        with open(path, "rb") as f:
                            raw = f.read()
                        enc = chardet.detect(raw).get("encoding") or "utf-8"
                        html = raw.decode(enc, errors="ignore")
                    except Exception:
                        with open(path, "r", encoding="utf-8", errors="ignore") as f:
                            html = f.read()
                    import re
                    text = re.sub(r"<[^>]+>", " ", html)
                    return (text, None)
                if ext in {".xlsx", ".xlsm"}:
                    try:
                        from openpyxl import load_workbook
                        wb = load_workbook(filename=path, read_only=True, data_only=True)
                        texts = []
                        for ws in wb.worksheets:
                            for row in ws.iter_rows(values_only=True):
                                vals = [str(v) for v in row if v is not None]
                                if vals:
                                    texts.append("\\t".join(vals))
                        return ("\\n".join(texts), None)
                    except Exception:
                        return ("", None)
                if ext == ".xls":
                    try:
                        import xlrd
                        book = xlrd.open_workbook(path)
                        texts = []
                        for si in range(book.nsheets):
                            sh = book.sheet_by_index(si)
                            for ri in range(sh.nrows):
                                vals = [str(sh.cell_value(ri, ci)) for ci in range(sh.ncols)]
                                if any(v.strip() for v in vals):
                                    texts.append("\\t".join(vals))
                        return ("\\n".join(texts), None)
                    except Exception:
                        return ("", None)
                # Fallback
                try:
                    import chardet
                    with open(path, "rb") as f:
                        raw = f.read()
                    head = raw[:8192]
                    if b"\\x00" in head:
                        return ("", None)
                    printable = sum(1 for b in head if 32 <= b <= 126 or b in (9, 10, 13))
                    if len(head) > 0 and (printable / max(1, len(head))) < 0.6:
                        return ("", None)
                    enc = chardet.detect(raw).get("encoding") or "utf-8"
                    text = raw.decode(enc, errors="ignore")
                    return (text, None)
                except Exception:
                    try:
                        with open(path, "r", encoding="utf-8", errors="ignore") as f:
                            return (f.read(), None)
                    except Exception:
                        return ("", None)
            except Exception:
                return ("", None)

        def _approx_num_tokens(s):
            try:
                import tiktoken
                enc = tiktoken.get_encoding("cl100k_base")
                return len(enc.encode(s))
            except Exception:
                return max(1, int(len(s) / 4))

        def iter_sliding_windows(text, max_tokens=800, overlap_tokens=150):
            text = text.strip()
            if not text:
                return []
            paragraphs = [p.strip() for p in text.split("\\n\\n") if p.strip()]
            if not paragraphs:
                paragraphs = [text]

            chunks = []
            buf = ""
            for p in paragraphs:
                if not buf:
                    buf = p
                else:
                    tmp = f"{buf}\\n\\n{p}"
                    if _approx_num_tokens(tmp) <= max_tokens:
                        buf = tmp
                    else:
                        chunks.append(buf)
                        tail_chars = max(0, overlap_tokens * 4)
                        buf_tail = buf[-tail_chars:] if tail_chars > 0 else ""
                        buf = (buf_tail + "\\n\\n" + p).strip()
                        while _approx_num_tokens(buf) > max_tokens:
                            take_chars = max(1, (max_tokens - overlap_tokens) * 4)
                            sub = buf[:take_chars]
                            chunks.append(sub)
                            buf = buf[take_chars:]
            if buf:
                chunks.append(buf)
            return chunks

        @dataclass
        class MetaEntry:
            id: int
            path: str
            folder: str
            mtime_iso: str
            page: Optional[int]
            text_hash: str
            text: str
            deleted: bool = False

        class RAGIndex:
            def __init__(self, dim=None, embed_model="text-embedding-3-small"):
                self.dim = dim or 0
                self.index = None
                self.embed_model = embed_model
                self.size = 0
                self._local_embedder = None
                self._initialization_error = None
                
                print(f"Initializing RAGIndex with dim={self.dim}, embed_model={embed_model}", file=sys.stderr)
                
                # Try to initialize with error handling
                try:
                    self._lazy_index()
                    print("RAGIndex initialization successful", file=sys.stderr)
                except Exception as e:
                    self._initialization_error = str(e)
                    print(f"Warning: RAGIndex initialization warning: {e}", file=sys.stderr)
                    if traceback:
                        traceback.print_exc()

            def _lazy_index(self):
                print(f"_lazy_index called, HAVE_FAISS={HAVE_FAISS}, current index={self.index is not None}", file=sys.stderr)
                if not HAVE_FAISS:
                    raise RuntimeError("faiss not installed")
                if self.index is None:
                    print(f"Index is None, checking for existing index at {FAISS_PATH}", file=sys.stderr)
                    if os.path.isfile(FAISS_PATH):
                        try:
                            print("Loading existing FAISS index...", file=sys.stderr)
                            self.index = faiss.read_index(FAISS_PATH)
                            self.size = self.index.ntotal
                            if self.dim == 0 and hasattr(self.index, 'd'):
                                self.dim = int(getattr(self.index, 'd', 0))
                            print(f"Loaded existing index: size={self.size}, dim={self.dim}", file=sys.stderr)
                            return self.index
                        except Exception as e:
                            print(f"Error loading existing index: {e}", file=sys.stderr)
                            if self.dim > 0:
                                print(f"Creating new index with dim={self.dim}", file=sys.stderr)
                                self.index = faiss.IndexFlatIP(self.dim)
                                self.size = 0
                                return self.index
                            self.size = 0
                            return self.index
                    if self.dim > 0:
                        print(f"Creating new index with dim={self.dim}", file=sys.stderr)
                        self.index = faiss.IndexFlatIP(self.dim)
                        self.size = 0
                    else:
                        print("No dimension set, returning None index", file=sys.stderr)
                return self.index

            def _normalize(self, X):
                import numpy as np
                norms = np.linalg.norm(X, axis=1, keepdims=True) + 1e-12
                return X / norms

            def _lazy_local_embedder(self):
                if self._local_embedder is not None:
                    return self._local_embedder
                if not HAVE_SENTENCE_TRANSFORMERS:
                    raise RuntimeError("sentence-transformers not installed")
                
                try:
                    model_id = "google/embeddinggemma-300m"  # Use the same model as Swift
                    print(f"Loading embedding model: {model_id}", file=sys.stderr)
                    self._local_embedder = SentenceTransformer(model_id)
                    print("Embedding model loaded successfully", file=sys.stderr)
                    return self._local_embedder
                except Exception as e:
                    print(f"Error loading embedding model: {e}", file=sys.stderr)
                    # Fallback to a simpler model if available
                    try:
                        print("Trying fallback model: all-MiniLM-L6-v2", file=sys.stderr)
                        self._local_embedder = SentenceTransformer('all-MiniLM-L6-v2')
                        print("Fallback model loaded successfully", file=sys.stderr)
                        return self._local_embedder
                    except Exception as e2:
                        print(f"Fallback model also failed: {e2}", file=sys.stderr)
                        raise RuntimeError(f"Failed to load any embedding model: {e}, {e2}")

            def _embed(self, texts):
                import numpy as np
                try:
                    print(f"Embedding {len(texts)} texts...", file=sys.stderr)
                    
                    # Process texts in smaller batches to avoid memory issues
                    batch_size = min(8, len(texts))  # Smaller batch size for stability
                    all_embeddings = []
                    
                    for i in range(0, len(texts), batch_size):
                        batch_texts = texts[i:i + batch_size]
                        print(f"Processing batch {i//batch_size + 1}/{(len(texts) + batch_size - 1)//batch_size} with {len(batch_texts)} texts", file=sys.stderr)
                        print(f"Batch text lengths: {[len(t) for t in batch_texts]}", file=sys.stderr)
                        
                        # Use local embeddings via sentence-transformers
                        model = self._lazy_local_embedder()
                        print("Model loaded, encoding batch...", file=sys.stderr)
                        
                        # Encode with explicit thread safety
                        vecs = model.encode(
                            batch_texts, 
                            convert_to_numpy=True, 
                            normalize_embeddings=True,
                            show_progress_bar=False,
                            batch_size=1  # Process one text at a time within the batch
                        )
                        print(f"Batch encoded to shape: {vecs.shape}", file=sys.stderr)
                        all_embeddings.append(vecs)
                        
                        # Clean up memory after each batch
                        del vecs
                        gc.collect()
                        
                        # Small delay to prevent overwhelming the system
                        time.sleep(0.1)
                    
                    # Combine all embeddings
                    if all_embeddings:
                        arr = np.vstack(all_embeddings).astype("float32")
                    else:
                        arr = np.array([]).astype("float32")
                    
                    print(f"Combined embeddings shape: {arr.shape}", file=sys.stderr)
                    
                    # Set dimension if unknown
                    if arr.size > 0 and self.dim <= 0 and arr.shape[1] > 0:
                        self.dim = int(arr.shape[1])
                        print(f"Set dimension to: {self.dim}", file=sys.stderr)
                    
                    # Ensure FAISS index matches the embedding dimension
                    if arr.size > 0 and HAVE_FAISS:
                        current_d = int(getattr(self.index, 'd', 0)) if self.index is not None else 0
                        if self.index is None or current_d != self.dim:
                            self.index = faiss.IndexFlatIP(self.dim)
                            print(f"Created new FAISS index with dimension: {self.dim}", file=sys.stderr)
                    
                    print(f"Embedding successful, returning array of shape: {arr.shape}", file=sys.stderr)
                    return arr
                except Exception as e:
                    print(f"Error in _embed: {e}", file=sys.stderr)
                    if traceback:
                        traceback.print_exc()
                    raise

            def _append_meta(self, metas):
                ensure_dirs()
                temp_path = META_PATH + ".tmp"
                with open(temp_path, "a", encoding="utf-8") as w:
                    for m in metas:
                        w.write(json.dumps(m.__dict__, ensure_ascii=False) + "\\n")
                with open(temp_path, "r", encoding="utf-8") as r, open(META_PATH, "a", encoding="utf-8") as out:
                    out.write(r.read())
                os.remove(temp_path)

            def _soft_delete_path(self, path):
                if not os.path.isfile(META_PATH):
                    return 0
                temp = META_PATH + ".rewrite.tmp"
                changed = 0
                with open(META_PATH, "r", encoding="utf-8") as r, open(temp, "w", encoding="utf-8") as w:
                    for line in r:
                        try:
                            obj = json.loads(line)
                        except Exception:
                            continue
                        if obj.get("path") == path and not obj.get("deleted", False):
                            obj["deleted"] = True
                            changed += 1
                        w.write(json.dumps(obj, ensure_ascii=False) + "\\n")
                os.replace(temp, META_PATH)
                return changed

            def index_file(self, path, force_reindex=False):
                ensure_dirs()
                ext = os.path.splitext(path)[1].lower()
                if (not INDEX_ALL_FILE_TYPES) and (ext not in SUPPORTED_EXTS):
                    return {"added": 0, "deleted": 0}
                
                # Skip temporary files
                filename = os.path.basename(path)
                if filename.startswith('~$') or filename.startswith('.~'):
                    print(f"Skipping temporary file: {path}", file=sys.stderr)
                    return {"added": 0, "deleted": 0}
                
                try:
                    st = os.stat(path)
                    mtime_iso = datetime.fromtimestamp(st.st_mtime).isoformat()
                except Exception:
                    return {"added": 0, "deleted": 0}

                try:
                    self._lazy_index()
                except Exception:
                    pass

                manifest = _load_manifest()
                rec = manifest.get(path)
                cur_sig = f"{int(st.st_mtime)}:{st.st_size}"
                print(f"Checking file {path}: sig={cur_sig}, existing_rec={rec is not None}, size={self.size}, force_reindex={force_reindex}", file=sys.stderr)
                if not force_reindex and rec and rec.get("sig") == cur_sig and self.size > 0:
                    print(f"Skipping {path} - already indexed with same signature", file=sys.stderr)
                    return {"added": 0, "deleted": 0}
                elif force_reindex and rec:
                    print(f"Force reindexing {path} - will delete existing chunks first", file=sys.stderr)

                deleted = self._soft_delete_path(path)

                full_text, paged = load_text_from_file(path)
                print(f"Loaded text from {path}: {len(full_text)} chars, paged: {paged is not None}", file=sys.stderr)
                if not full_text.strip():
                    print(f"No text content in {path}, skipping", file=sys.stderr)
                    return {"added": 0, "deleted": deleted}

                entries = []
                if paged:
                    print(f"Processing {len(paged)} pages", file=sys.stderr)
                    for page_num, page_text in paged:
                        chunks = iter_sliding_windows(page_text)
                        print(f"Page {page_num}: {len(chunks)} chunks", file=sys.stderr)
                        for chunk in chunks:
                            if chunk.strip():
                                entries.append((page_num, chunk))
                else:
                    chunks = iter_sliding_windows(full_text)
                    print(f"Single text: {len(chunks)} chunks", file=sys.stderr)
                    for chunk in chunks:
                        if chunk.strip():
                            entries.append((None, chunk))

                print(f"Total entries created: {len(entries)}", file=sys.stderr)
                if not entries:
                    print(f"No entries created for {path}, skipping", file=sys.stderr)
                    return {"added": 0, "deleted": deleted}

                metas = []
                texts = []
                seen = set()
                folder = os.path.basename(os.path.dirname(path))
                for page, chunk in entries:
                    h = sha1_of_text(chunk, path, page)
                    if h in seen:
                        continue
                    seen.add(h)
                    metas.append(MetaEntry(id=self.size + len(texts), path=path, folder=folder, mtime_iso=mtime_iso,
                                           page=page, text_hash=h, text=chunk, deleted=False))
                    texts.append(chunk)

                if not texts:
                    print(f"No texts to embed for {path}", file=sys.stderr)
                    return {"added": 0, "deleted": deleted}

                print(f"About to embed {len(texts)} texts for {path}", file=sys.stderr)
                print(f"Text lengths: {[len(t) for t in texts[:3]]}...", file=sys.stderr)  # Show first 3 text lengths
                try:
                    vecs = self._embed(texts)
                    print(f"Successfully embedded {len(texts)} texts, shape: {vecs.shape}", file=sys.stderr)
                    
                    index = self._lazy_index()
                    if index is None:
                        print("ERROR: Index is None after lazy loading", file=sys.stderr)
                        return {"added": 0, "deleted": deleted}
                    
                    print(f"Adding {len(texts)} vectors to index (current size: {self.size})", file=sys.stderr)
                    index.add(vecs)
                    self.size = index.ntotal
                    print(f"Index size after adding: {self.size}", file=sys.stderr)

                    # Persist index
                    ensure_dirs()
                    temp_index_path = FAISS_PATH + ".tmp"
                    if HAVE_FAISS:
                        print(f"Writing index to {FAISS_PATH}", file=sys.stderr)
                        faiss.write_index(index, temp_index_path)
                        os.replace(temp_index_path, FAISS_PATH)
                        print("Index written successfully", file=sys.stderr)

                    # Append meta
                    print(f"Appending {len(metas)} meta entries", file=sys.stderr)
                    self._append_meta(metas)

                    # Update manifest entry
                    manifest[path] = {"sig": cur_sig, "mtime_iso": mtime_iso, "chunks": len(texts)}
                    _save_manifest(manifest)
                    print(f"Updated manifest for {path} with {len(texts)} chunks", file=sys.stderr)

                    result = {"added": len(texts), "deleted": deleted}
                    print(f"Returning result for {path}: {result}", file=sys.stderr)
                    
                    # Reset timeout after successful file processing
                    try:
                        signal.alarm(1800)
                    except:
                        pass  # Ignore if signal is not available
                    
                    return result
                except Exception as e:
                    print(f"Error processing {path}: {e}", file=sys.stderr)
                    if traceback:
                        traceback.print_exc()
                    return {"added": 0, "deleted": deleted}

            def index_folders(self, folders, excludes=None, progress_cb=None, force_reindex=False):
                try:
                    excludes = excludes or []
                    file_list = []
                    
                    # Validate folders and collect files with error handling
                    for root in folders:
                        try:
                            if not os.path.isdir(root):
                                print(f"Warning: Not a directory: {root}", file=sys.stderr)
                                continue
                            for dirpath, dirnames, filenames in os.walk(root):
                                try:
                                    dirnames[:] = [d for d in dirnames if not d.startswith('.') and not any(x in d for x in excludes)]
                                    for fn in filenames:
                                        if fn.startswith('.'):
                                            continue
                                        # Skip temporary files and other excluded patterns
                                        if any(fn.startswith(pattern.replace('*', '')) for pattern in excludes if '*' in pattern):
                                            continue
                                        if any(pattern in fn for pattern in excludes if '*' not in pattern):
                                            continue
                                        path = os.path.join(dirpath, fn)
                                        if INDEX_ALL_FILE_TYPES:
                                            file_list.append(path)
                                        else:
                                            ext = os.path.splitext(path)[1].lower()
                                            if ext in SUPPORTED_EXTS:
                                                file_list.append(path)
                                except Exception as e:
                                    print(f"Warning: Error walking directory {dirpath}: {e}", file=sys.stderr)
                                    continue
                        except Exception as e:
                            print(f"Warning: Error processing folder {root}: {e}", file=sys.stderr)
                            continue

                    total = len(file_list)
                    processed = 0
                    added = 0
                    deleted = 0

                    # Emit initial progress
                    try:
                        if progress_cb:
                            progress_cb(0, total, "")
                    except Exception as e:
                        print(f"Warning: Progress callback error: {e}", file=sys.stderr)

                    # Process files with comprehensive error handling
                    for path in file_list:
                        try:
                            res = self.index_file(path, force_reindex=force_reindex)
                            added += res.get("added", 0)
                            deleted += res.get("deleted", 0)
                        except Exception as e:
                            print(f"Warning: Error indexing file {path}: {e}", file=sys.stderr)
                            if traceback:
                                traceback.print_exc()
                        finally:
                            processed += 1
                            try:
                                if progress_cb:
                                    progress_cb(processed, total, path)
                            except Exception as e:
                                print(f"Warning: Progress callback error: {e}", file=sys.stderr)

                    return {"added": added, "deleted": deleted}
                    
                except Exception as e:
                    print(f"Error in index_folders: {e}", file=sys.stderr)
                    if traceback:
                        traceback.print_exc()
                    return {"added": 0, "deleted": 0, "error": str(e)}

        def main():
            try:
                # Add debugging output
                print("Starting Python indexer main function...", file=sys.stderr)
                print("Environment variables set", file=sys.stderr)
                
                # Signal that we're ready to receive commands
                print("READY", flush=True)
                print("READY signal sent", file=sys.stderr)
                
                # Read input from stdin line by line with timeout
                
                def timeout_handler(signum, frame):
                    print("Timeout reached, exiting gracefully", file=sys.stderr)
                    sys.exit(0)
                
                # Set timeout to 30 minutes for large files
                signal.signal(signal.SIGALRM, timeout_handler)
                signal.alarm(1800)
                
                try:
                    for line in sys.stdin:
                        try:
                            # Validate input
                            if not line.strip():
                                continue
                            
                            input_data = json.loads(line.strip())
                            action = input_data.get("action")
                            
                            if action == "index_folders":
                                # Reset timeout for new indexing operation
                                try:
                                    signal.alarm(1800)  # Reset to 30 minutes
                                except:
                                    pass  # Ignore if signal is not available
                                
                                folders = input_data.get("folders", [])
                                excludes = input_data.get("excludes", [])
                                replace = input_data.get("replace", False)
                                
                                # Validate folders
                                if not folders:
                                    error_result = {
                                        "type": "result",
                                        "success": False,
                                        "error": "No folders provided for indexing"
                                    }
                                    print(json.dumps(error_result), flush=True)
                                    continue
                                
                                # Check if folders exist
                                valid_folders = []
                                for folder in folders:
                                    if os.path.exists(folder) and os.path.isdir(folder):
                                        valid_folders.append(folder)
                                    else:
                                        print(f"Warning: Folder does not exist or is not a directory: {folder}", file=sys.stderr)
                                
                                if not valid_folders:
                                    error_result = {
                                        "type": "result",
                                        "success": False,
                                        "error": "No valid folders found for indexing"
                                    }
                                    print(json.dumps(error_result), flush=True)
                                    continue
                                
                                try:
                                    if replace:
                                        # Clear existing index safely
                                        for path in [FAISS_PATH, META_PATH, MANIFEST_PATH]:
                                            try:
                                                if os.path.exists(path):
                                                    os.remove(path)
                                            except Exception as e:
                                                print(f"Warning: Could not remove {path}: {e}", file=sys.stderr)
                                    
                                    # Initialize RAG index with error handling
                                    try:
                                        idx = RAGIndex()
                                    except Exception as e:
                                        error_result = {
                                            "type": "result",
                                            "success": False,
                                            "error": f"Failed to initialize RAG index: {str(e)}"
                                        }
                                        print(json.dumps(error_result), flush=True)
                                        continue
                                    
                                    def progress_cb(processed, total, current_path):
                                        try:
                                            progress_data = {
                                                "type": "progress",
                                                "processed": processed,
                                                "total": total,
                                                "current_path": current_path,
                                                "percentage": (processed / total * 100) if total > 0 else 0
                                            }
                                            print(json.dumps(progress_data), flush=True)
                                        except Exception as e:
                                            print(f"Warning: Progress callback error: {e}", file=sys.stderr)
                                    
                                    # Perform indexing with comprehensive error handling
                                    try:
                                        result = idx.index_folders(valid_folders, excludes=excludes, progress_cb=progress_cb, force_reindex=replace)
                                        result["size"] = idx.size
                                        
                                        # Send final result
                                        final_result = {
                                            "type": "result",
                                            "success": True,
                                            "data": result
                                        }
                                        print(json.dumps(final_result), flush=True)
                                        
                                    except Exception as e:
                                        error_result = {
                                            "type": "result",
                                            "success": False,
                                            "error": f"Indexing failed: {str(e)}"
                                        }
                                        print(json.dumps(error_result), flush=True)
                                
                                except Exception as e:
                                    error_result = {
                                        "type": "result",
                                        "success": False,
                                        "error": f"Failed to process index_folders command: {str(e)}"
                                    }
                                    print(json.dumps(error_result), flush=True)
                                
                            elif action == "get_status":
                                try:
                                    status = {
                                        "folders": [],
                                        "chunks": 0,
                                        "last_update": None
                                    }
                                    
                                    if os.path.isfile(FAISS_PATH) and os.path.isfile(META_PATH):
                                        try:
                                            idx = RAGIndex()
                                            idx._lazy_index()
                                            status["chunks"] = idx.size
                                        except Exception as e:
                                            print(f"Warning: Could not load index for status: {e}", file=sys.stderr)
                                            status["chunks"] = 0
                                    
                                    result = {
                                        "type": "result",
                                        "success": True,
                                        "data": status
                                    }
                                    print(json.dumps(result), flush=True)
                                    
                                except Exception as e:
                                    error_result = {
                                        "type": "result",
                                        "success": False,
                                        "error": f"Failed to get status: {str(e)}"
                                    }
                                    print(json.dumps(error_result), flush=True)
                                
                            elif action == "clear_index":
                                try:
                                    # Clear all index files
                                    cleared_files = []
                                    for path in [FAISS_PATH, META_PATH, MANIFEST_PATH]:
                                        try:
                                            if os.path.exists(path):
                                                os.remove(path)
                                                cleared_files.append(path)
                                        except Exception as e:
                                            print(f"Warning: Could not remove {path}: {e}", file=sys.stderr)
                                    
                                    result = {
                                        "type": "result",
                                        "success": True,
                                        "data": {
                                            "cleared_files": cleared_files,
                                            "message": f"Cleared {len(cleared_files)} index files"
                                        }
                                    }
                                    print(json.dumps(result), flush=True)
                                    
                                except Exception as e:
                                    error_result = {
                                        "type": "result",
                                        "success": False,
                                        "error": f"Failed to clear index: {str(e)}"
                                    }
                                    print(json.dumps(error_result), flush=True)
                                
                            elif action == "get_embeddings":
                                try:
                                    if not os.path.isfile(FAISS_PATH) or not os.path.isfile(META_PATH):
                                        error_result = {
                                            "type": "result",
                                            "success": False,
                                            "error": "No index found"
                                        }
                                        print(json.dumps(error_result), flush=True)
                                        continue
                                    
                                    # Load FAISS index and metadata
                                    idx = RAGIndex()
                                    idx._lazy_index()
                                    
                                    if idx.index is None or idx.size == 0:
                                        error_result = {
                                            "type": "result",
                                            "success": False,
                                            "error": "Empty index"
                                        }
                                        print(json.dumps(error_result), flush=True)
                                        continue
                                    
                                    # Read metadata
                                    embeddings_data = []
                                    with open(META_PATH, "r", encoding="utf-8") as f:
                                        for line in f:
                                            try:
                                                obj = json.loads(line.strip())
                                                if not obj.get("deleted", False):
                                                    embeddings_data.append({
                                                        "id": obj.get("id"),
                                                        "path": obj.get("path"),
                                                        "text": obj.get("text"),
                                                        "page": obj.get("page")
                                                    })
                                            except Exception:
                                                continue
                                    
                                    # Get embeddings from FAISS index
                                    if HAVE_FAISS and idx.index is not None:
                                        # Get all vectors from FAISS index
                                        vectors = idx.index.reconstruct_n(0, idx.size)
                                        vectors_list = vectors.tolist()
                                        
                                        # Match embeddings with metadata
                                        for i, meta in enumerate(embeddings_data):
                                            if i < len(vectors_list):
                                                meta["embedding"] = vectors_list[i]
                                    
                                    result = {
                                        "type": "result",
                                        "success": True,
                                        "data": {
                                            "embeddings": embeddings_data,
                                            "dimension": idx.dim,
                                            "count": len(embeddings_data)
                                        }
                                    }
                                    print(json.dumps(result), flush=True)
                                    
                                except Exception as e:
                                    error_result = {
                                        "type": "result",
                                        "success": False,
                                        "error": f"Failed to get embeddings: {str(e)}"
                                    }
                                    print(json.dumps(error_result), flush=True)
                                
                            else:
                                error_result = {
                                    "type": "result",
                                    "success": False,
                                    "error": f"Unknown action: {action}"
                                }
                                print(json.dumps(error_result), flush=True)
                            
                        except Exception as e:
                            error_result = {
                                "type": "result",
                                "success": False,
                                "error": f"Error processing input line: {str(e)}"
                            }
                            print(json.dumps(error_result), flush=True)
                
                except Exception as e:
                    error_result = {
                        "type": "result",
                        "success": False,
                        "error": f"Fatal error in main loop: {str(e)}"
                    }
                    print(json.dumps(error_result), flush=True)
            
            except Exception as e:
                error_result = {
                    "type": "result",
                    "success": False,
                    "error": f"Outermost fatal error in main: {str(e)}"
                }
                print(json.dumps(error_result), flush=True)

        if __name__ == "__main__":
            main()
        """
    }
    
    func startProcess() throws {
        // Stop any existing process first
        stopProcess()
        
        // Create a new process
        let process = Process()
        
        // Try to find the virtual environment Python first
        let venvPythonPath = "/Users/stv/Desktop/Business/Smart light/.venv/bin/python3"
        if FileManager.default.fileExists(atPath: venvPythonPath) {
            process.executableURL = URL(fileURLWithPath: venvPythonPath)
            print("[PythonIndexerService] Using virtual environment Python: \(venvPythonPath)")
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            print("[PythonIndexerService] Using system Python: /usr/bin/python3")
        }
        
        // Set up pipes
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Set up environment variables to avoid Python path issues
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = ""
        environment["PYTHONHOME"] = ""
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment
        
        // Create the Python indexer script
        let pythonScript = createIndexerScript()
        
        // Write script to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("indexer_\(UUID().uuidString).py")
        
        do {
            try pythonScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            process.arguments = [scriptURL.path]
        } catch {
            throw NSError(domain: "PythonIndexer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create Python script: \(error)"])
        }
        
        // Update instance variables
        self.pythonProcess = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        
        // Start the process
        do {
            try process.run()
            print("[PythonIndexerService] Python indexer process started")
        } catch {
            throw NSError(domain: "PythonIndexer", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to start Python process: \(error)"])
        }
        
        // Wait for READY signal from Python process
        let startTime = Date()
        var allOutput = ""
        var lastOutputTime = startTime
        
        while Date().timeIntervalSince(startTime) < 30.0 { // 30 second timeout
            // Check both stderr and stdout for READY signal
            let stderrData = errorPipe.fileHandleForReading.availableData
            let stdoutData = outputPipe.fileHandleForReading.availableData
            
            if !stderrData.isEmpty {
                lastOutputTime = Date()
                if let output = String(data: stderrData, encoding: .utf8) {
                    allOutput += output
                    print("[PythonIndexerService] Python stderr: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            
            if !stdoutData.isEmpty {
                lastOutputTime = Date()
                if let output = String(data: stdoutData, encoding: .utf8) {
                    allOutput += output
                    print("[PythonIndexerService] Python stdout: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            
            // Check accumulated output, not just current chunk
            if allOutput.contains("READY") {
                print("[PythonIndexerService] Python indexer is ready")
                return
            }
            
            // Check if we haven't received any output for too long
            if Date().timeIntervalSince(lastOutputTime) > 10.0 && allOutput.isEmpty {
                print("[PythonIndexerService] No output from Python process for 10 seconds")
            }
            
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        print("[PythonIndexerService] Timeout waiting for READY signal from Python indexer")
        print("[PythonIndexerService] All Python output received: \(allOutput)")
        throw NSError(domain: "PythonIndexer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Python indexer process failed to start or respond in time"])
    }
    
    func stopProcess() {
        if let process = pythonProcess {
            process.terminate()
            process.waitUntilExit()
            print("[PythonIndexerService] Python indexer process stopped")
        }
        
        // Clean up pipes
        inputPipe?.fileHandleForWriting.closeFile()
        outputPipe?.fileHandleForReading.closeFile()
        errorPipe?.fileHandleForReading.closeFile()
        
        pythonProcess = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }
    
    func indexFolders(_ folders: [String], excludes: [String] = [], replace: Bool = false, progress: ((Double, String) -> Void)? = nil) throws -> [String: Any] {
        // Validate input
        guard !folders.isEmpty else {
            throw NSError(domain: "PythonIndexer", code: -10, userInfo: [NSLocalizedDescriptionKey: "No folders provided for indexing"])
        }
        
        // Check if folders exist
        let validFolders = folders.filter { 
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !validFolders.isEmpty else {
            throw NSError(domain: "PythonIndexer", code: -11, userInfo: [NSLocalizedDescriptionKey: "No valid folders found for indexing"])
        }
        
        guard let process = pythonProcess, process.isRunning,
              let inputPipe = inputPipe, let outputPipe = outputPipe, let errorPipe = errorPipe else {
            throw NSError(domain: "PythonIndexer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Python process not running"])
        }
        
        let request = [
            "action": "index_folders",
            "folders": validFolders,
            "excludes": excludes,
            "replace": replace
        ] as [String: Any]
        
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestString = String(data: requestData, encoding: .utf8)!
        
        print("[PythonIndexerService] Sending index request for \(folders.count) folders")
        
        // Send request (add newline for line-by-line reading)
        let requestWithNewline = requestString + "\n"
        inputPipe.fileHandleForWriting.write(requestWithNewline.data(using: .utf8)!)
        
        // Start a background thread to read and print stderr during indexing
        let stderrQueue = DispatchQueue(label: "com.pythonindexer.stderr")
        stderrQueue.async {
            while self.isProcessRunning {
                let data = errorPipe.fileHandleForReading.availableData
                if !data.isEmpty {
                    if let str = String(data: data, encoding: .utf8) {
                        print("[PythonIndexerService] Python stderr during indexing: \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        
        // Read response line by line incrementally
        let startTime = Date()
        var buffer = ""
        let timeout = 1800.0 // 30 minute timeout for indexing to match Python script timeout
        
        var lastProgressTime = startTime
        var lastProgressValue = 0.0
        
        while Date().timeIntervalSince(startTime) < timeout {
            let data = outputPipe.fileHandleForReading.availableData
            if !data.isEmpty {
                lastProgressTime = Date() // Reset progress timer when we get data
                if let newString = String(data: data, encoding: .utf8) {
                    buffer += newString
                    var lines = buffer.components(separatedBy: "\n")
                    if !newString.hasSuffix("\n") {
                        buffer = lines.popLast() ?? ""
                    } else {
                        buffer = ""
                    }
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty { continue }
                        if let lineData = trimmed.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                            if let type = json["type"] as? String {
                                if type == "progress" {
                                    if let processed = json["processed"] as? Int,
                                       let total = json["total"] as? Int,
                                       let currentPath = json["current_path"] as? String {
                                        let progressValue = total > 0 ? Double(processed) / Double(total) : 0.0
                                        lastProgressValue = progressValue
                                        progress?(progressValue, currentPath)
                                    }
                                } else if type == "result" {
                                    if let success = json["success"] as? Bool, success,
                                       let data = json["data"] as? [String: Any] {
                                        print("[PythonIndexerService] Received final result: \(data)")
                                        return data
                                    } else if let error = json["error"] as? String {
                                        throw NSError(domain: "PythonIndexer", code: -3, userInfo: [NSLocalizedDescriptionKey: error])
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                // Check if we've been waiting too long without progress
                let timeSinceLastProgress = Date().timeIntervalSince(lastProgressTime)
                if timeSinceLastProgress > 60.0 { // 1 minute without progress
                    let elapsed = Date().timeIntervalSince(startTime)
                    print("[PythonIndexerService] ⚠️ No progress for \(Int(timeSinceLastProgress))s (total elapsed: \(Int(elapsed))s, progress: \(Int(lastProgressValue * 100))%)")
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        throw NSError(domain: "PythonIndexer", code: -4, userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for response from Python indexer"])
    }
    
    func getStatus() throws -> [String: Any] {
        guard let process = pythonProcess, process.isRunning,
              let inputPipe = inputPipe, let outputPipe = outputPipe else {
            throw NSError(domain: "PythonIndexer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Python process not running"])
        }
        
        let request = ["action": "get_status"]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestString = String(data: requestData, encoding: .utf8)!
        
        // Send request
        inputPipe.fileHandleForWriting.write(requestString.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()
        
        // Read response
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let outputString = String(data: outputData, encoding: .utf8) ?? ""
        
        guard let data = outputString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = json["success"] as? Bool, success,
              let result = json["data"] as? [String: Any] else {
            throw NSError(domain: "PythonIndexer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse status response"])
        }
        
        return result
    }
    
    func getEmbeddings() throws -> [String: Any] {
        guard let process = pythonProcess, process.isRunning,
              let inputPipe = inputPipe, let outputPipe = outputPipe else {
            throw NSError(domain: "PythonIndexer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Python process not running"])
        }
        
        let request = ["action": "get_embeddings"]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestString = String(data: requestData, encoding: .utf8)!
        
        // Send request
        inputPipe.fileHandleForWriting.write(requestString.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()
        
        // Read response
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let outputString = String(data: outputData, encoding: .utf8) ?? ""
        
        guard let data = outputString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = json["success"] as? Bool, success,
              let result = json["data"] as? [String: Any] else {
            throw NSError(domain: "PythonIndexer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse embeddings response"])
        }
        
        return result
    }
    
    func clearIndex() throws -> [String: Any] {
        guard let process = pythonProcess, process.isRunning,
              let inputPipe = inputPipe, let outputPipe = outputPipe else {
            throw NSError(domain: "PythonIndexer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Python process not running"])
        }
        
        let request = ["action": "clear_index"]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestString = String(data: requestData, encoding: .utf8)!
        
        // Send request
        inputPipe.fileHandleForWriting.write(requestString.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()
        
        // Read response
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let outputString = String(data: outputData, encoding: .utf8) ?? ""
        
        guard let data = outputString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = json["success"] as? Bool, success,
              let result = json["data"] as? [String: Any] else {
            throw NSError(domain: "PythonIndexer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse clear index response"])
        }
        
        return result
    }
    
    deinit {
        stopProcess()
    }
}