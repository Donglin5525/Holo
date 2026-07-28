//
//  ChatScrollBehaviorStandaloneTests.swift
//  HoloTests
//
//  运行方式：
//  swiftc ChatScrollBehavior.swift ChatScrollBehaviorStandaloneTests.swift -o /tmp/chat-scroll-tests
//  /tmp/chat-scroll-tests
//

import Foundation

@main
struct ChatScrollBehaviorStandaloneTests {

    static func main() {
        testMessageMutationClassification()
        testHistoryLoadGateOnlyTriggersOncePerTopVisit()
        testHistoryLoadGateDoesNotTriggerWithoutUserGesture()
        testScrollGeometryPreservesViewportAndHandlesShortContent()
        testHistoryPageResultDistinguishesFailure()
        print("ChatScrollBehaviorStandaloneTests passed")
    }

    private static func testMessageMutationClassification() {
        let first = id(1)
        let second = id(2)
        let third = id(3)

        expect(
            ChatMessageListMutation.classify(previous: [], current: [first, second])
                == .initial(count: 2),
            "首次消息加载应识别为 initial"
        )
        expect(
            ChatMessageListMutation.classify(
                previous: [second, third],
                current: [first, second, third]
            ) == .prepended(count: 1),
            "顶部插入历史消息应识别为 prepended"
        )
        expect(
            ChatMessageListMutation.classify(
                previous: [first, second],
                current: [first, second, third]
            ) == .appended(count: 1),
            "底部收到新消息应识别为 appended"
        )
        expect(
            ChatMessageListMutation.classify(
                previous: [first, second],
                current: [second, third]
            ) == .replaced,
            "删除或混合变化不能误判成 prepend/append"
        )
    }

    private static func testHistoryLoadGateOnlyTriggersOncePerTopVisit() {
        var gate = ChatHistoryLoadGate()
        let atTop = viewport(nearTop: true, interacting: true, sequence: 1)
        let awayFromTop = viewport(nearTop: false, interacting: true, sequence: 1)
        let nextGestureAtTop = viewport(nearTop: true, interacting: true, sequence: 2)

        expect(
            gate.shouldLoad(viewport: atTop, canLoad: true, isLoading: false),
            "第一次由手势进入顶部预取区应加载"
        )
        expect(
            !gate.shouldLoad(viewport: atTop, canLoad: true, isLoading: false),
            "同一次到顶不能级联加载第二页"
        )
        expect(
            !gate.shouldLoad(viewport: awayFromTop, canLoad: true, isLoading: false),
            "同一次手势离开顶部不应加载"
        )
        expect(
            !gate.shouldLoad(viewport: atTop, canLoad: true, isLoading: false),
            "同一手势的惯性滚动再次到顶也不能连载第二页"
        )
        expect(
            gate.shouldLoad(viewport: nextGestureAtTop, canLoad: true, isLoading: false),
            "新一轮手势回到顶部后应允许加载下一页"
        )
    }

    private static func testHistoryLoadGateDoesNotTriggerWithoutUserGesture() {
        var gate = ChatHistoryLoadGate()

        expect(
            !gate.shouldLoad(
                viewport: viewport(nearTop: true, interacting: false, sequence: 0),
                canLoad: true,
                isLoading: false
            ),
            "首屏布局或程序滚动到顶部不能自动连载历史"
        )
        expect(
            !gate.shouldLoad(
                viewport: viewport(nearTop: true, interacting: true, sequence: 1),
                canLoad: false,
                isLoading: false
            ),
            "没有更早消息时不能发起分页"
        )
    }

    private static func testHistoryPageResultDistinguishesFailure() {
        expect(
            ChatHistoryPageResult.loaded(16, hasEarlierMessages: true)
                == ChatHistoryPageResult(
                    insertedCount: 16,
                    hasEarlierMessages: true,
                    didFail: false
                ),
            "成功分页应保留插入数量"
        )
        expect(
            ChatHistoryPageResult.failed(hasEarlierMessages: true).didFail,
            "读取失败必须与到达历史起点区分"
        )
    }

    private static func testScrollGeometryPreservesViewportAndHandlesShortContent() {
        expect(
            ChatScrollGeometry.offsetPreservingViewport(
                currentOffsetY: 320,
                prependedHeight: 840
            ) == 1_160,
            "顶部增加内容时 offset 必须增加同样高度，屏幕文字才不会跳"
        )
        expect(
            ChatScrollGeometry.maximumOffsetY(
                contentHeight: 300,
                viewportHeight: 700,
                topInset: 12,
                bottomInset: 20
            ) == -12,
            "内容短于视口时合法底部应退化为顶部 inset"
        )
        expect(
            ChatScrollGeometry.isPinnedToBottom(
                currentOffsetY: 940,
                maximumOffsetY: 1_000,
                threshold: 72
            ),
            "底部阈值内的流式增长应继续跟随"
        )
        expect(
            !ChatScrollGeometry.isPinnedToBottom(
                currentOffsetY: 800,
                maximumOffsetY: 1_000,
                threshold: 72
            ),
            "用户离开底部后流式增长不能抢回位置"
        )
        expect(
            ChatScrollGeometry.shouldAnimateJumpToBottom(
                distance: 700,
                viewportHeight: 800
            ),
            "短距离回底应保留动画"
        )
        expect(
            !ChatScrollGeometry.shouldAnimateJumpToBottom(
                distance: 12_000,
                viewportHeight: 800
            ),
            "长距离回底必须直接完成，不能让默认动画沿途加载几十秒"
        )
    }

    private static func viewport(
        nearTop: Bool,
        interacting: Bool,
        sequence: Int
    ) -> ChatScrollViewportState {
        ChatScrollViewportState(
            isNearTop: nearTop,
            isNearBottom: !nearTop,
            showsJumpToLatest: nearTop,
            isUserInteracting: interacting,
            interactionSequence: sequence
        )
    }

    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("FAIL: \(message)")
        }
    }
}
