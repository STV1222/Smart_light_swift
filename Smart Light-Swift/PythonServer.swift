//
//  PythonServer.swift
//  Smart Light-Swift
//
//  Created by STV on 24/09/2025.
//

import Foundation
import SwiftUI
import Combine   // add this

final class PythonServer: ObservableObject {
    private var process: Process?
    @Published private(set) var isRunning = false

    func start(pathToScript: String, port: Int = 8008, extraEnv: [String: String] = [:]) {
        guard process == nil else { return }
        let p = Process()

        let scriptURL = URL(fileURLWithPath: pathToScript)
        let scriptDirectory = scriptURL.deletingLastPathComponent()
        p.currentDirectoryURL = scriptDirectory

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // Load .env from script directory and user home locations
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let candidateEnvFiles = [
            scriptDirectory.appendingPathComponent(".env"),
            homeDir.appendingPathComponent(".smartlight/.env"),
            homeDir.appendingPathComponent(".env")
        ]
        for fileURL in candidateEnvFiles {
            let loaded = Self.parseDotEnvFile(at: fileURL)
            guard !loaded.isEmpty else { continue }
            loaded.forEach { env[$0.key] = $0.value }
        }

        // Allow overrides from Settings (takes precedence)
        extraEnv.forEach { env[$0.key] = $0.value }
        // Prefer venv python if present, else system python
        let venvPython = scriptDirectory.appendingPathComponent(".venv/bin/python3").path
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            p.executableURL = URL(fileURLWithPath: venvPython)
            p.arguments = [pathToScript, "--server", "--host", "127.0.0.1", "--port", "\(port)"]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", pathToScript, "--server", "--host", "127.0.0.1", "--port", "\(port)"]
        }

        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            NSLog("[smartlight-server] \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            NSLog("[smartlight-server][ERR] \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.process = nil
                self?.isRunning = false
            }
        }

        do {
            try p.run()
            process = p
            isRunning = true
        } catch {
            print("Failed to start server: \(error)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }
}

private extension PythonServer {
    static func parseDotEnvFile(at url: URL) -> [String: String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in content.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            // Basic unescape for common sequences
            value = value.replacingOccurrences(of: "\\n", with: "\n")
            value = value.replacingOccurrences(of: "\\t", with: "\t")
            result[key] = value
        }
        return result
    }
}
