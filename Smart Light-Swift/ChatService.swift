//
//  ChatService.swift
//  Smart Light-Swift
//
//  Created by STV on 24/09/2025.
//

import Foundation

struct ChatResponse: Decodable {
    let answer: String
    let hits: [AnyDecodable]?
    let low_confidence: Bool?
}
struct AnyDecodable: Decodable {}

final class ChatService {}

extension ChatService {}
