//
//  ChatScrollBehavior.swift
//  Holo
//
//  对话列表的纯逻辑滚动策略。
//  与 UIKit/SwiftUI 解耦，保证分页触发和消息变更判断可以独立回归。
//

import Foundation

/// 只发布会影响界面决策的滚动状态，避免手指每移动一个像素都触发 SwiftUI 重绘。
nonisolated struct ChatScrollViewportState: Equatable, Sendable {
    let isNearTop: Bool
    let isNearBottom: Bool
    let showsJumpToLatest: Bool
    let isUserInteracting: Bool
    /// 每次手指开始一轮新的拖动时递增，用于限制“一次手势最多读取一页”。
    let interactionSequence: Int

    static let initial = ChatScrollViewportState(
        isNearTop: false,
        isNearBottom: true,
        showsJumpToLatest: false,
        isUserInteracting: false,
        interactionSequence: 0
    )
}

nonisolated struct ChatMessageListSignature: Equatable, Sendable {
    let count: Int
    let firstID: UUID?
    let lastID: UUID?

    init(count: Int, firstID: UUID?, lastID: UUID?) {
        self.count = count
        self.firstID = firstID
        self.lastID = lastID
    }

    init(ids: [UUID]) {
        self.init(count: ids.count, firstID: ids.first, lastID: ids.last)
    }
}

/// 用首尾 ID 判断列表变化来自哪里，防止 prepend 历史消息被误判为“收到新消息”。
nonisolated enum ChatMessageListMutation: Equatable, Sendable {
    case unchanged
    case initial(count: Int)
    case prepended(count: Int)
    case appended(count: Int)
    case replaced

    static func classify(previous: [UUID], current: [UUID]) -> Self {
        classify(
            previous: ChatMessageListSignature(ids: previous),
            current: ChatMessageListSignature(ids: current)
        )
    }

    static func classify(
        previous: ChatMessageListSignature,
        current: ChatMessageListSignature
    ) -> Self {
        guard previous != current else { return .unchanged }
        guard previous.count > 0 else { return .initial(count: current.count) }
        guard current.count > previous.count else { return .replaced }

        let insertedCount = current.count - previous.count
        if current.lastID == previous.lastID,
           current.firstID != previous.firstID {
            return .prepended(count: insertedCount)
        }
        if current.firstID == previous.firstID,
           current.lastID != previous.lastID {
            return .appended(count: insertedCount)
        }
        return .replaced
    }
}

/// 顶部预取门闩：一次真实拖动手势最多触发一页，抬手后再次上滑才允许读取下一页。
/// 这样既支持连续自然上滑，也不会在一次快速甩动的惯性阶段级联加载很多页。
nonisolated struct ChatHistoryLoadGate: Equatable, Sendable {
    private(set) var lastTriggeredInteractionSequence: Int?

    mutating func shouldLoad(
        viewport: ChatScrollViewportState,
        canLoad: Bool,
        isLoading: Bool
    ) -> Bool {
        guard viewport.isNearTop,
              viewport.isUserInteracting,
              viewport.interactionSequence > 0,
              lastTriggeredInteractionSequence != viewport.interactionSequence,
              canLoad,
              !isLoading else {
            return false
        }

        lastTriggeredInteractionSequence = viewport.interactionSequence
        return true
    }
}

/// UIScrollView 几何计算的纯函数，集中定义短内容、底部 inset 和 prepend 补偿规则。
nonisolated enum ChatScrollGeometry {
    static func maximumOffsetY(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(
            -topInset,
            contentHeight - viewportHeight + bottomInset
        )
    }

    static func offsetPreservingViewport(
        currentOffsetY: CGFloat,
        prependedHeight: CGFloat
    ) -> CGFloat {
        currentOffsetY + prependedHeight
    }

    static func isPinnedToBottom(
        currentOffsetY: CGFloat,
        maximumOffsetY: CGFloat,
        threshold: CGFloat
    ) -> Bool {
        maximumOffsetY - currentOffsetY <= threshold
    }

    /// 回底动画只覆盖较短距离。长距离若继续使用 UIScrollView 默认动画，
    /// LazyVStack 会在沿途持续补布局并改变 contentSize，导致动画反复追逐新终点。
    static func shouldAnimateJumpToBottom(
        distance: CGFloat,
        viewportHeight: CGFloat,
        maximumAnimatedViewports: CGFloat = 1.5
    ) -> Bool {
        guard distance > 0 else { return false }
        let maximumAnimatedDistance = max(320, viewportHeight * maximumAnimatedViewports)
        return distance <= maximumAnimatedDistance
    }
}

/// 历史页读取结果；失败与“已经到最早消息”必须区分，避免失败后入口永久消失。
nonisolated struct ChatHistoryPageResult: Equatable, Sendable {
    let insertedCount: Int
    let hasEarlierMessages: Bool
    let didFail: Bool

    static func loaded(_ count: Int, hasEarlierMessages: Bool) -> Self {
        ChatHistoryPageResult(
            insertedCount: count,
            hasEarlierMessages: hasEarlierMessages,
            didFail: false
        )
    }

    static func failed(hasEarlierMessages: Bool) -> Self {
        ChatHistoryPageResult(
            insertedCount: 0,
            hasEarlierMessages: hasEarlierMessages,
            didFail: true
        )
    }
}
