//
//  EmbeddingService.swift
//  Smart Light-Swift
//

import Foundation
#if canImport(PythonKit)
import PythonKit
#endif

protocol EmbeddingService {
    func embed(texts: [String], asQuery: Bool) throws -> [[Float]]
    var dimension: Int { get }
}




