//
//  PythonBootstrap.swift
//  Smart Light-Swift
//

import Foundation

#if canImport(PythonKit)
import PythonKit
#endif

enum PythonBootstrap {
    static func initialize() {
        // Prevent re-initialization which would crash PythonKit if the library is loaded twice
        struct Once { static var didInit = false }
        if Once.didInit { return }
        Once.didInit = true
        // Absolute project paths per request
        let projectRoot = "/Users/stv/Desktop/Business/Smart light"
        let venvRoot = projectRoot + "/.venv"

        // We'll set PYTHONHOME after resolving the framework root below.
        // Ensure our package is importable by default
        var pythonPath = projectRoot
        // Propagate .env to Python if present (best-effort)
        // Export .env into process env so Python can read it too
        let exported = DotEnv.exportToProcessEnv()
        if let hf = exported["HF_TOKEN"], !hf.isEmpty {
            setenv("HUGGINGFACE_HUB_TOKEN", hf, 1)
            setenv("HF_TOKEN", hf, 1)
        }

        #if canImport(PythonKit)
        // Decide Python library to load
        var candidates: [String] = []
        // 1) Respect explicit env override if present
        if let envLib = ProcessInfo.processInfo.environment["PYTHON_LIBRARY"], !envLib.isEmpty {
            candidates.append(envLib)
        }
        // 2) Venv dylib (may not exist on some installers)
        candidates.append(venvRoot + "/lib/libpython3.12.dylib")
        // 3) Framework binary from python.org installer
        candidates.append("/Library/Frameworks/Python.framework/Versions/3.12/Python")
        candidates.append("/Library/Frameworks/Python.framework/Versions/Current/Python")
        // 4) Homebrew framework locations (Apple Silicon / Intel)
        candidates.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.12/Python")
        candidates.append("/opt/homebrew/Frameworks/Python.framework/Versions/Current/Python")
        candidates.append("/usr/local/Frameworks/Python.framework/Versions/3.12/Python")
        candidates.append("/usr/local/Frameworks/Python.framework/Versions/Current/Python")

        // Pick the first existing path
        let fm = FileManager.default
        if let path = candidates.first(where: { fm.fileExists(atPath: $0) }) {
            setenv("PYTHON_LIBRARY", path, 1)
            PythonLibrary.useLibrary(at: path)
        }
        // Prefer framework home for stdlib to avoid 'encodings' error
        let homeCandidates = [
            "/Library/Frameworks/Python.framework/Versions/3.12",
            "/opt/homebrew/Frameworks/Python.framework/Versions/3.12",
            "/usr/local/Frameworks/Python.framework/Versions/3.12"
        ]
        if let home = homeCandidates.first(where: { fm.fileExists(atPath: $0) }) {
            setenv("PYTHONHOME", home, 1)
        }
        // Don't set PYTHONHOME to venv - it causes encodings module issues
        // Add venv site-packages to PYTHONPATH
        let sitePackages = venvRoot + "/lib/python3.12/site-packages"
        if fm.fileExists(atPath: sitePackages) {
            pythonPath += ":" + sitePackages
        }
        setenv("PYTHONPATH", pythonPath, 1)
        // _ = Python.version // Not needed since we're not using PythonKit
        #endif
    }
}


