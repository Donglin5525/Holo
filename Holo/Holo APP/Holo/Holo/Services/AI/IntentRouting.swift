//
//  IntentRouting.swift
//  Holo
//
//  IntentRouter 的可测试协议抽象
//

import Foundation

/// IntentRouter 的协议抽象，便于 ConversationCoordinator 测试时注入 mock
protocol IntentRouting {
    func route(_ result: ParsedResult, originalInput: String?) async throws -> IntentRouter.RouteResult
    func previewCategoryMatch(extractedData: [String: String]?, type: TransactionType) async throws -> (primary: String?, sub: String?)
}

extension IntentRouter: IntentRouting {}
