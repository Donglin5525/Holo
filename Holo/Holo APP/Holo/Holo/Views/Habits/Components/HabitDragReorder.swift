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

    /// 松手且顺序有变化时同步回调（视图层负责落库；draggedId 供失败提示定位）
    var onCommit: ((HabitReorderSection, [UUID], UUID) -> Void)?

    var isInteracting: Bool { isLifting || draggingId != nil }

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
        guard session == nil else { return }
        let baseline = lastSeen[section] ?? []
        guard baseline.contains(id) else { return }
        HabitReorderFeel.liftHaptic()
        isLifting = true
        draggingId = id
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

        // 跨行换位：位移越过相邻行（实测高度 + 间距）的一半
        if var order = orders[s.section] {
            let d = translationY - s.anchorShift
            let rowHeight = { [weak self] (id: UUID) -> CGFloat in
                self?.rowHeights[id] ?? HabitReorderFeel.fallbackRowHeight
            }
            if d > 0, s.currentIndex < order.count - 1 {
                let step = rowHeight(order[s.currentIndex + 1]) + s.spacing
                if d > step / 2 {
                    order.swapAt(s.currentIndex, s.currentIndex + 1)
                    orders[s.section] = order
                    s.anchorShift += step
                    s.currentIndex += 1
                    HabitReorderFeel.swapHaptic()
                }
            } else if d < 0, s.currentIndex > 0 {
                let step = rowHeight(order[s.currentIndex - 1]) + s.spacing
                if -d > step / 2 {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + HabitReorderFeel.interactionLockWindow) { [weak self] in
            self?.isLifting = false
        }
        if changed, let finalOrder, let draggedId {
            onCommit?(section, finalOrder, draggedId)
        }
    }

    /// 取消会话不落库（弹层打断等场景由宿主调用；当前无触发点，留作语义完备）
    func cancelDrag() {
        guard let s = session else { return }
        session = nil
        stopAutoScroll()
        withAnimation(HabitReorderFeel.settleSpring) {
            draggingId = nil
            dragOffsetY = 0
            orders[s.section] = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + HabitReorderFeel.interactionLockWindow) { [weak self] in
            self?.isLifting = false
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
