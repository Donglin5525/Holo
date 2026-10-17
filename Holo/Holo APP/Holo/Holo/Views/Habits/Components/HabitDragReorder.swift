//
//  HabitDragReorder.swift
//  Holo
//
//  今天页习惯行长按拖拽排序（2026-10-07）：
//  首页功能按钮同款「长按激活 → 拖动跟手 → 跨行换位 → 松手落座」组合手势
//  （HomeView 真机验证过的 sequenced 模式），垂直列表化改造：
//  · 激活：medium 触觉 + 抬起（scale + 阴影）
//  · 跟手：拖拽项 offset = 手指位移 − 累计锚点位移（换位瞬间不跳变）
//  · 让位：ForEach 按会话顺序渲染 + snappy 弹性，其余行平滑滑动
//  · 换位阈值 = 相邻行实测高度一半（onGeometryChange 收集，不按估算）
//  · 落座：spring 吸附 + selection 触觉在每次换位时已给
//  · 拖到屏幕上下边缘自动滚动（ScrollViewReader 逐行推进）
//  手感参数集中在 HabitReorderFeel，真机微调只动一处。
//

import SwiftUI
import Combine

// MARK: - 分组

/// 拖拽重排的独立顺序槽（一次拖拽会话只属于一个槽）。
/// 今天页是单一连续列表（2026-10-07 东林拍板去掉每日/周月分组，跨频率自由拖）。
enum HabitReorderSection {
    case today
    case sortSheet
}

// MARK: - 手感参数

/// 全部可调参数集中于此（真机手感验收后按反馈微调）
enum HabitReorderFeel {
    /// 长按激活时长（秒）
    static let liftDelay: TimeInterval = 0.45
    /// 激活瞬间触觉
    static func liftHaptic() { HapticManager.medium() }
    /// 抬起缩放
    static let liftScale: CGFloat = 1.03
    /// 抬起投影
    static let liftShadowOpacity: Double = 0.18
    static let liftShadowRadius: CGFloat = 12
    /// 拖动开始判定阈值（pt，防普通点击卷入）
    static let dragMinimumDistance: CGFloat = 6
    /// 换位触觉
    static func swapHaptic() { HapticManager.selection() }
    /// 松手落座弹性
    static let settleSpring: Animation = .spring(response: 0.4, dampingFraction: 0.6)
    /// 长按激活/结束后行内按钮的防误触锁定窗口（秒；HomeView 真机坑：立即解锁会让
    /// 「长按震动后不拖直接抬手」误触发行内按钮）
    static let interactionLockWindow: TimeInterval = 0.2
    /// 行高收集不到时的兜底高度（pt；理论上可见行必已收集）
    static let fallbackRowHeight: CGFloat = 80
    /// 自动滚动：触发带（距屏幕上下边缘 pt）与步进间隔
    static let autoScrollEdge: CGFloat = 70
    static let autoScrollInterval: TimeInterval = 0.09
}

// MARK: - 重排模型

@MainActor
final class HabitListReorderModel: ObservableObject {

    /// 当前拖拽行（nil = 无会话）
    @Published private(set) var draggingId: UUID?
    /// 拖拽项跟手偏移（已扣除锚点位移；仅拖拽行消费）
    @Published private(set) var dragOffsetY: CGFloat = 0
    /// 长按激活锁定（激活到松手后一小段；行内按钮回调 guard 它防误触）
    @Published private(set) var isLifting = false
    /// 各分组会话顺序（nil = 未参与/无会话，渲染回退 baseline）
    @Published private(set) var orders: [HabitReorderSection: [UUID]] = [:]

    private struct Session {
        var section: HabitReorderSection
        var spacing: CGFloat
        var fromIndex: Int
        var currentIndex: Int
        var liveTranslation: CGFloat
        var anchorShift: CGFloat
    }

    private var session: Session?
    /// 各分组最近一次渲染 baseline（beginDrag 的底序来源；非 published，body 内写不触发刷新）
    private var lastSeen: [HabitReorderSection: [UUID]] = [:]
    /// 行实测高度（onGeometryChange 收集）
    private var rowHeights: [UUID: CGFloat] = [:]
    /// 自动滚动代理（宿主 ScrollView onAppear 注入）
    var scrollProxy: ScrollViewProxy?

    private var autoScrollTask: Task<Void, Never>?
    private var autoScrollDirection: Int = 0

    /// 手势会话最近一次活动时刻（激活/拖动/换位/自动滚动步进）。
    /// isInteracting 的清除不能只押「drag.onEnded 必然回调」——系统打断
    /// （来电/通知横幅/控制中心/切换 App）不保证回调，2026-10-11 东林真机
    /// 「习惯记录点击不动」即会话状态永久卡死后被全页 guard 静默吞点击。
    private var lastGestureActivity: Date?

    /// 会话陈旧窗口：超过即视为手势已死。它同时是「onEnded 丢失后点击被吞的
    /// 最大时长」——2026-10-15 东林真机复报「拖完换序后点打卡间歇性不动」，
    /// iOS 26 长按序列手势正常完成也可能丢 onEnded（速查表实锤不可全信），
    /// 8s 吞点击窗口太长。正常拖拽中 dragMoved 手指动 1pt 就刷新、边缘按住
    /// 时自动滚动 0.09s 步进刷新，都远在窗口内续命；只有「按住完全不动」
    /// 超窗，而超窗不清会话（手指可能仍在屏上），仅由 admitInteraction
    /// 在点击时刻校验放行。
    private static let sessionStaleWindow: TimeInterval = 2

    /// isLifting 延迟解锁的代数令牌：新会话开始时递增，作废上一会话挂起的
    /// 解锁闭包（陈旧清场后立即重开新会话时防误清）
    private var liftClearGeneration = 0

    /// 会话是否已陈旧（手势回调彻底丢失后的自愈判据）
    private var isSessionStale: Bool {
        guard let lastActivity = lastGestureActivity else { return true }
        return Date().timeIntervalSince(lastActivity) >= Self.sessionStaleWindow
    }

    /// 松手且顺序有变化时同步回调（视图层负责落库；draggedId 供失败提示定位）
    var onCommit: ((HabitReorderSection, [UUID], UUID) -> Void)?

    /// 相邻换位前置校验（视图注入）。今天页 P2 分节渲染后，全局顺序数组里
    /// 相邻两行可能分属不同节——跨节换位会打乱节内顺序且视觉无反馈，
    /// 视图注入「同节才可换」的谓词；nil = 不限制（排序弹层等平面列表）。
    var canSwapAdjacent: ((UUID, UUID) -> Bool)?

    var isInteracting: Bool {
        guard isLifting || draggingId != nil else { return false }
        return !isSessionStale
    }

    /// 行内按钮点击时刻的放行校验（视图层 guard 一律走它，不直接读 isInteracting）：
    /// 会话陈旧 = 手势回调已丢失、手指早已离屏 —— 就地清场残留会话并放行本次
    /// 点击，不等陈旧窗口被动走完（吞点击窗口从「等满窗口」缩到「点一下即愈」）；
    /// 会话活跃 = 手指大概率仍在屏上 —— 拒绝，防拖拽误触行内按钮。
    func admitInteraction() -> Bool {
        guard isLifting || draggingId != nil else { return true }
        guard isSessionStale else { return false }
        cancelDrag()
        return true
    }

    /// 测试专用：把会话活动时刻回拨（模拟手势回调彻底丢失后的时间流逝）
    func test_backdateGestureActivity(by interval: TimeInterval) {
        lastGestureActivity = lastGestureActivity?.addingTimeInterval(-interval)
    }

    // MARK: 渲染查询

    /// 会话顺序优先，无会话回退 baseline；顺手记录 baseline 供激活时取底序
    func effectiveIds(_ section: HabitReorderSection, baseline: [UUID]) -> [UUID] {
        lastSeen[section] = baseline
        return orders[section] ?? baseline
    }

    func noteHeight(_ height: CGFloat, for id: UUID) {
        rowHeights[id] = height
    }

    // MARK: 手势回调（HabitReorderableRow 驱动）

    func beginDrag(id: UUID, section: HabitReorderSection, spacing: CGFloat) {
        if session != nil {
            // 陈旧死会话（手势回调已彻底丢失）就地清场，拖拽功能可用；
            // 活会话内拒绝重入
            guard isSessionStale else { return }
            cancelDrag()
        }
        let baseline = lastSeen[section] ?? []
        guard baseline.contains(id) else { return }
        HabitReorderFeel.liftHaptic()
        liftClearGeneration += 1 // 作废上一会话挂起的 isLifting 解锁
        isLifting = true
        draggingId = id
        lastGestureActivity = Date()
        orders[section] = baseline
        session = Session(
            section: section,
            spacing: spacing,
            fromIndex: baseline.firstIndex(of: id) ?? 0,
            currentIndex: baseline.firstIndex(of: id) ?? 0,
            liveTranslation: 0,
            anchorShift: 0
        )
        dragOffsetY = 0
    }

    func dragMoved(translationY: CGFloat, locationY: CGFloat) {
        guard var s = session, let draggingId else { return }
        s.liveTranslation = translationY
        lastGestureActivity = Date()

        // 跨行换位：位移越过相邻行（实测高度 + 间距）的一半；跨节不换（分节渲染）
        if var order = orders[s.section] {
            let d = translationY - s.anchorShift
            let rowHeight = { [weak self] (id: UUID) -> CGFloat in
                self?.rowHeights[id] ?? HabitReorderFeel.fallbackRowHeight
            }
            if d > 0, s.currentIndex < order.count - 1 {
                let nextId = order[s.currentIndex + 1]
                let canSwap = canSwapAdjacent?(order[s.currentIndex], nextId) ?? true
                let step = rowHeight(nextId) + s.spacing
                if canSwap, d > step / 2 {
                    order.swapAt(s.currentIndex, s.currentIndex + 1)
                    orders[s.section] = order
                    s.anchorShift += step
                    s.currentIndex += 1
                    HabitReorderFeel.swapHaptic()
                }
            } else if d < 0, s.currentIndex > 0 {
                let prevId = order[s.currentIndex - 1]
                let canSwap = canSwapAdjacent?(order[s.currentIndex], prevId) ?? true
                let step = rowHeight(prevId) + s.spacing
                if canSwap, -d > step / 2 {
                    order.swapAt(s.currentIndex - 1, s.currentIndex)
                    orders[s.section] = order
                    s.anchorShift -= step
                    s.currentIndex -= 1
                    HabitReorderFeel.swapHaptic()
                }
            }
        }

        session = s
        dragOffsetY = translationY - s.anchorShift
        updateAutoScroll(locationY: locationY)
    }

    func endDrag() {
        guard let s = session else { return }
        session = nil
        stopAutoScroll()
        lastGestureActivity = Date()

        let section = s.section
        let draggedId = draggingId
        let finalOrder = orders[section]
        let baseline = lastSeen[section] ?? []
        let changed = finalOrder != nil && finalOrder != baseline

        withAnimation(HabitReorderFeel.settleSpring) {
            draggingId = nil
            dragOffsetY = 0
            orders[section] = nil
        }
        // 防误触锁定延迟解除（同 runloop 清会让行内按钮 tap 放行，真机复现过）
        liftClearGeneration += 1
        let generation = liftClearGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + HabitReorderFeel.interactionLockWindow) { [weak self] in
            guard let self, self.liftClearGeneration == generation else { return }
            self.isLifting = false
        }
        if changed, let finalOrder, let draggedId {
            onCommit?(section, finalOrder, draggedId)
        }
    }

    /// 取消会话不落库（弹层打断等场景由宿主调用）
    func cancelDrag() {
        guard let s = session else { return }
        session = nil
        stopAutoScroll()
        lastGestureActivity = Date()
        withAnimation(HabitReorderFeel.settleSpring) {
            draggingId = nil
            dragOffsetY = 0
            orders[s.section] = nil
        }
        liftClearGeneration += 1
        let generation = liftClearGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + HabitReorderFeel.interactionLockWindow) { [weak self] in
            guard let self, self.liftClearGeneration == generation else { return }
            self.isLifting = false
        }
    }

    // MARK: 按钮式移动（排序弹层上下箭头，与拖拽共用会话顺序与让位动画）

    func moveByOne(id: UUID, offset: Int, section: HabitReorderSection) {
        let baseline = orders[section] ?? lastSeen[section] ?? []
        guard !baseline.isEmpty else { return }
        var order = baseline
        if orders[section] == nil { orders[section] = order }
        guard let index = order.firstIndex(of: id) else { return }
        let target = index + offset
        guard target >= 0, target < order.count else { return }
        order.swapAt(index, target)
        orders[section] = order
        HabitReorderFeel.swapHaptic()
    }

    /// 排序弹层保存：取当前生效顺序（会话顺序或 baseline）
    func currentIds(_ section: HabitReorderSection) -> [UUID]? {
        orders[section] ?? lastSeen[section]
    }

    // MARK: 自动滚动

    private func updateAutoScroll(locationY: CGFloat) {
        if locationY < HabitReorderFeel.autoScrollEdge {
            startAutoScroll(direction: -1)
        } else if locationY > UIScreen.main.bounds.height - HabitReorderFeel.autoScrollEdge {
            startAutoScroll(direction: 1)
        } else {
            stopAutoScroll()
        }
    }

    private func startAutoScroll(direction: Int) {
        guard autoScrollDirection != direction, autoScrollTask == nil else { return }
        autoScrollDirection = direction
        autoScrollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.stepAutoScroll(direction: direction)
                try? await Task.sleep(for: .seconds(HabitReorderFeel.autoScrollInterval))
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollDirection = 0
    }

    /// 逐行推进：把拖拽行沿方向的下一位滚到可视区边缘；到列表尽头后保持 no-op
    private func stepAutoScroll(direction: Int) {
        guard let s = session,
              let order = orders[s.section],
              let draggingId,
              let proxy = scrollProxy else { return }
        let target = s.currentIndex + direction
        guard target >= 0, target < order.count else { return }
        withAnimation(nil) {
            proxy.scrollTo(order[target], anchor: direction > 0 ? .top : .bottom)
        }
        // 实际滚动发生 = 会话活着（手指停边缘不动时没有 dragMoved，靠这里保活）
        lastGestureActivity = Date()
    }
}

// MARK: - 行修饰器

extension View {
    /// 挂在重排列表行上：抬起视觉 + 跟手位移 + 长按拖拽手势 + 让位动画
    func habitReorderable(
        id: UUID,
        section: HabitReorderSection,
        spacing: CGFloat,
        model: HabitListReorderModel
    ) -> some View {
        modifier(HabitReorderableRow(id: id, section: section, spacing: spacing, model: model))
    }
}

private struct HabitReorderableRow: ViewModifier {

    let id: UUID
    let section: HabitReorderSection
    let spacing: CGFloat
    @ObservedObject var model: HabitListReorderModel

    func body(content: Content) -> some View {
        let isDragging = model.draggingId == id
        content
            .scaleEffect(isDragging ? HabitReorderFeel.liftScale : 1)
            .shadow(
                color: isDragging ? .black.opacity(HabitReorderFeel.liftShadowOpacity) : .clear,
                radius: isDragging ? HabitReorderFeel.liftShadowRadius : 0,
                x: 0,
                y: isDragging ? 6 : 0
            )
            .zIndex(isDragging ? 10 : 0)
            .offset(y: isDragging ? model.dragOffsetY : 0)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                model.noteHeight(newHeight, for: id)
            }
            // 行销毁（习惯被删/列表变更）时手势随之消失、onEnded 不会再回调，
            // 正被拖拽的行就地取消会话——不等陈旧自愈兜底
            .onDisappear {
                if model.draggingId == id { model.cancelDrag() }
            }
            .simultaneousGesture(reorderGesture)
            .animation(HoloAnimation.snappy, value: model.orders[section])
            .animation(HoloAnimation.snappy, value: isDragging)
    }

    /// HomeView 功能按钮同款组合手势：回调挂在组成手势上（长按达成激活、
    /// 拖动跟手、抬手落座），组合手势不再重复挂回调——真机已验证的可靠结构
    private var reorderGesture: some Gesture {
        let longPress = LongPressGesture(minimumDuration: HabitReorderFeel.liftDelay)
            .onEnded { _ in
                model.beginDrag(id: id, section: section, spacing: spacing)
            }
        let drag = DragGesture(minimumDistance: HabitReorderFeel.dragMinimumDistance, coordinateSpace: .global)
            .onChanged { value in
                model.dragMoved(translationY: value.translation.height, locationY: value.location.y)
            }
            .onEnded { _ in
                model.endDrag()
            }
        return longPress.sequenced(before: drag)
    }
}
