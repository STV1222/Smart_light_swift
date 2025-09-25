//
//  EnvDiagnostics.swift
//  Smart Light-Swift
//

import Foundation

#if canImport(PythonKit)
import PythonKit
#endif

enum EnvDiagnostics {
    static func verifyAndLog() {
        NSLog("[Env] Loading .env and exporting to process env…")
        let env = DotEnv.exportToProcessEnv()
        let keys = [
            "EMBEDDING_BACKEND",
            "LOCAL_EMBEDDING_MODEL",
            "HF_TOKEN",
            "OPENAI_API_KEY"
        ]
        for k in keys {
            let v = env[k] ?? ProcessInfo.processInfo.environment[k]
            let shown = (k == "HF_TOKEN" || k == "OPENAI_API_KEY") ? (v == nil ? "(nil)" : "(set)") : (v ?? "(nil)")
            NSLog("[Env] \(k)=\(shown)")
        }

        // Skip PythonKit checks since we're using LocalEmbeddingService
        NSLog("[Env][Py] Using LocalEmbeddingService; skipping PythonKit checks")
    }
}


