//
//  IntentRouting.swift
//  Holo
//
//  IntentRouter 的可测试协议抽象
//

import Foundation

/// IntentRouter 的协议抽象，便于 ConversationCoordinator 测试时注入 mock
protocol IntentRouting {
    func route(_ result: ParsedResult) async throws -> IntentRouter.RouteResult
}

extension IntentRouter: IntentRouting {}
