//
//  IndexingStatusManager.swift
//  Smart Light-Swift
//
//  Created by STV on 24/09/2025.
//

import Foundation
import SwiftUI
import Combine

/// Manages persistent indexing status across the app
class IndexingStatusManager: ObservableObject {
    static let shared = IndexingStatusManager()
    
    @Published var chunks: Int = 0
    @Published var foldersIndexed: [String] = []
    @Published var lastIndexedDate: Date? = nil
    
    private init() {
        // Load initial status from RagSession
        updateStatus()
    }
    
    /// Update status from current RagSession state
    func updateStatus() {
        DispatchQueue.main.async {
            self.chunks = RagSession.shared.getStoreCount()
            // Note: foldersIndexed is not directly available from RagSession
            // It will be updated when new indexing completes
        }
    }
    
    /// Update status when new indexing completes
    func updateFromNewIndexing(folders: [String]) {
        DispatchQueue.main.async {
            self.chunks = RagSession.shared.getStoreCount()
            self.foldersIndexed = folders
            self.lastIndexedDate = Date()
        }
    }
    
    /// Get a user-friendly status description
    var statusDescription: String {
        if chunks == 0 {
            return "No files indexed"
        } else if foldersIndexed.isEmpty {
            return "\(chunks) chunks indexed"
        } else {
            return "\(chunks) chunks from \(foldersIndexed.count) folder\(foldersIndexed.count == 1 ? "" : "s")"
        }
    }
    
    /// Get folder names for display
    var folderNames: [String] {
        return foldersIndexed.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}
