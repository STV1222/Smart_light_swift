import Foundation

// Protocol for all indexer types to ensure compatibility
protocol IndexerProtocol: Sendable {
    var indexedFolders: [String] { get }
    
    func index(folders: [String], progress: ((Double) -> Void)?, shouldCancel: (() -> Bool)?) throws
}

// Make existing indexers conform to the protocol
extension Indexer: IndexerProtocol {}
extension ParallelIndexer: IndexerProtocol {}
extension IncrementalIndexer: IndexerProtocol {}
