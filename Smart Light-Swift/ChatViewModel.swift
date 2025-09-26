//
//  ChatViewModel.swift
//  Smart Light-Swift
//
//  Created by STV on 24/09/2025.
//

import Foundation
import SwiftUI
import Combine

struct QAItem: Identifiable, Equatable {
    let id = UUID()
    let question: String
    let answer: String
}

final class ChatViewModel: ObservableObject {
    @Published var items: [QAItem] = []
    @Published var input: String = ""
    @Published var isLoading: Bool = false
    private let engine: RagEngine = {
        if RagSession.shared.engine == nil {
            // Always use Gemma embeddings
            RagSession.shared.initialize(embeddingBackend: "gemma")
        }
        return RagSession.shared.engine!
    }()

    func send() async {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input = ""
        
        // Set loading state
        await MainActor.run {
            isLoading = true
        }
        
        do {
            let ans = try await engine.answer(question: q)
            await MainActor.run {
                items.append(QAItem(question: q, answer: ans))
                isLoading = false
            }
        } catch {
            await MainActor.run {
                items.append(QAItem(question: q, answer: "Error: \(error.localizedDescription)"))
                isLoading = false
            }
        }
    }
}
