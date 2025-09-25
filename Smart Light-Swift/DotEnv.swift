//
//  DotEnv.swift
//  Smart Light-Swift
//

import Foundation

enum DotEnv {
    // Project and user-level .env locations
    private static let projectRoot = "/Users/stv/Desktop/Business/Smart light"
    private static let projectEnv = projectRoot + "/.env"
    private static let userEnv = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
        .appendingPathComponent(".smartlight/.env")

    private static var cache: [String: String] = load()

    static func get(_ key: String, default def: String? = nil) -> String? {
        return cache[key] ?? ProcessInfo.processInfo.environment[key] ?? def
    }

    static func all() -> [String: String] { cache }

    @discardableResult
    static func exportToProcessEnv() -> [String: String] {
        for (k, v) in cache { setenv(k, v, 1) }
        return cache
    }

    private static func load() -> [String: String] {
        var result: [String: String] = [:]
        var candidates: [String] = [projectEnv, userEnv]
        // Also try current working directory and bundle resource directory
        let cwd = FileManager.default.currentDirectoryPath
        candidates.append((cwd as NSString).appendingPathComponent(".env"))
        if let res = Bundle.main.resourceURL?.path {
            candidates.append((res as NSString).deletingLastPathComponent + "/.env")
            candidates.append((res as NSString).appendingPathComponent(".env"))
        }
        // De-duplicate
        candidates = Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
        for path in candidates {
            if !FileManager.default.fileExists(atPath: path) { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let s = try? String(contentsOfFile: path, encoding: .utf8) {
                NSLog("[Env] .env loaded from: \(path)")
                for raw in s.split(whereSeparator: \.isNewline) {
                    var line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.isEmpty || line.hasPrefix("#") { continue }
                    if line.hasPrefix("export ") { line.removeFirst(7) }
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                    var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                        v.removeFirst(); v.removeLast()
                    }
                    v = v.replacingOccurrences(of: "\\n", with: "\n")
                    v = v.replacingOccurrences(of: "\\t", with: "\t")
                    result[k] = v
                }
            }
        }
        return result
    }
}


