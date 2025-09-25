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
        do {
            let ans = try await engine.answer(question: q)
            items.append(QAItem(question: q, answer: ans))
        } catch {
            items.append(QAItem(question: q, answer: "Error: \(error.localizedDescription)"))
        }
    }
}
