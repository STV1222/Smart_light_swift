//
//  EmbeddingService.swift
//  Smart Light-Swift
//

import Foundation
#if canImport(PythonKit)
import PythonKit
#endif

protocol EmbeddingService: Sendable {
    func embed(texts: [String], asQuery: Bool, progress: ((Double) -> Void)?) throws -> [[Float]]
    var dimension: Int { get }
}




