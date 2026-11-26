//
//  TransactionCategoryReorder.swift
//  Holo
//
//  「记一笔」分类宫格长按拖拽排序（2026-11-09 空间优化）：
//  · 手势：原生长按达到 0.45 秒后开始排序并跟手；此前的位移交给滚动区。
//  · 长按原地松手（未拖动）= 打开现有「分类管理」页（承接被删的 ⚙管理 入口）
//  · 长按后拖动 = 排序：二维换位（拖拽位移 / 列宽行高 → 目标格 index），
//    其余格 identity 保持平滑让位，原位留虚线占位
//  · 落位即写库（onCommit → FinanceRepository.reorderCategories，模型层字段对管理页同样生效）
//  · 旧系统 SwiftUI 序列手势的收尾兜底（三路幂等、先到者生效）：
//    ① Drag.onEnded（最小距离 0，原地松手也回调）；② 格内 @GestureState 在手势结束/取消时
//    必被 SwiftUI 复位；③ 本格持有会话时 Button 收到的抬手点击。再叠会话陈旧窗口 +
//    admitInteraction 点击时刻自愈（他格点击）；松手后 0.2s 防误触锁定窗口防长按松手误触
//

import SwiftUI
import Combine
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 手感参数

/// 全部可调参数集中于此（与 HabitReorderFeel 同源约定）
enum CategoryGridReorderFeel {
    /// 列数（与分类宫格布局一致）
    static let columns = 5
    /// 列间距 / 行间距（与 LazyVGrid 布局参数一致）
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 14
    /// 长按激活时长（秒）
    static let liftDelay: TimeInterval = 0.45
    /// 拖动语义阈值（pt）：位移超过才算「拖动」，否则松手=打开分类管理
    static let dragMinimumDistance: CGFloat = 6
    /// 抬起缩放（48 → 56 ≈ 1.17，原型 E）
    static let liftScale: CGFloat = 1.17
    /// 抬起投影
    static let liftShadowOpacity: Double = 0.25
    static let liftShadowRadius: CGFloat = 10
    /// 松手落座弹性
    static let settleSpring: Animation = .spring(response: 0.4, dampingFraction: 0.6)
    /// 长按激活/结束后格点击的防误触锁定窗口（秒；习惯模块真机坑）
    static let interactionLockWindow: TimeInterval = 0.2
    /// 会话陈旧窗口（秒）：超过即视为手势回调已丢失，点击时刻自愈清场
    static let sessionStaleWindow: TimeInterval = 2
}

// MARK: - 排序会话模型

@MainActor
final class CategoryGridReorderModel: ObservableObject {

    /// 当前被拖格 id（nil = 无会话）
    @Published private(set) var draggingId: UUID?
    /// 被拖格跟手偏移（已扣除换位锚点位移；仅被拖格消费）
    @Published private(set) var dragTranslation: CGSize = .zero
    /// 长按激活锁定（激活到松手后一小段；格点击回调 guard 它防误触）
    @Published private(set) var isLifting = false
    /// 会话顺序（nil = 无会话，渲染回退 baseline）
    @Published private(set) var order: [UUID]?

    /// 会话顺序有变化且松手时同步回调（视图层负责组装完整序并落库）
    var onCommit: ((_ ids: [UUID], _ draggedId: UUID) -> Void)?
    /// 长按原地松手（未拖动）回调（打开现有分类管理页）
    var onOpenManagement: (() -> Void)?

    // MARK: 会话私有状态

    private var fromIndex = 0
    private var currentIndex = 0
    private var anchor: CGSize = .zero
    /// 已越过拖动阈值（区分「长按松手开管理页」与「拖动落位排序」）
    private var didDrag = false
    /// 激活时的 baseline（落位时判断顺序是否变化）
    private var sessionBaseline: [UUID] = []
    /// 手势会话最近一次活动时刻（onEnded 丢失的自愈判据，同习惯模块）
    private var lastGestureActivity: Date?
    /// isLifting 延迟解锁的代数令牌（新会话作废上一会话挂起的解锁闭包）
    private var liftClearGeneration = 0

    // 几何输入（视图层回调上下文收集，非 published，不触发重绘）
    /// 列宽（换位计算的横向步长）
    private(set) var columnWidth: CGFloat = 60
    /// 格实测高度（cell onGeometryChange 收集；收集前按 48+6+14 估算）
    private(set) var cellHeight: CGFloat = 68
    /// 渲染 baseline（effectiveOrder 顺手记录，激活时取底序）
    private var lastSeenBaseline: [UUID] = []

    // MARK: - 渲染查询

    /// 会话顺序优先，无会话回退 baseline（body 内调用：只写非 published 状态）
    func effectiveOrder(baseline: [UUID]) -> [UUID] {
        lastSeenBaseline = baseline
        return order ?? baseline
    }

    /// 会话进行中（含松手后的防误触锁定窗口）：宿主据此锁滚动
    var isSessionActive: Bool {
        isLifting || draggingId != nil
    }

    /// 会话是否已陈旧（手势回调彻底丢失后的自愈判据）
    private var isSessionStale: Bool {
        guard let lastActivity = lastGestureActivity else { return true }
        return Date().timeIntervalSince(lastActivity) >= CategoryGridReorderFeel.sessionStaleWindow
    }

    /// 格点击时刻的放行校验（不直接读 isSessionActive）：
    /// 陈旧 = 手势已死、手指早已离屏——就地清场放行本次点击；
    /// 活跃 = 手指大概率仍在屏上或刚松手——拒绝（防长按松手/拖拽误触）
    func admitInteraction() -> Bool {
        guard isSessionActive else { return true }
        guard isSessionStale else { return false }
        cancelDrag()
        return true
    }

    // MARK: - 几何收集

    func noteGridMetrics(columnWidth: CGFloat) {
        self.columnWidth = max(columnWidth, 20)
    }

    func noteCellHeight(_ height: CGFloat) {
        cellHeight = max(height, 40)
    }

    // MARK: - 手势回调

    /// 长按达成：激活抬起（此时还不知道用户要拖动还是原地松手）
    func beginPress(id: UUID) {
        if isSessionActive {
            // 陈旧死会话（手势回调已彻底丢失）就地清场；活会话内拒绝重入
            guard isSessionStale else { return }
            cancelDrag()
        }
        let baseline = lastSeenBaseline
        guard let index = baseline.firstIndex(of: id) else { return }
        HapticManager.medium()
        liftClearGeneration += 1 // 作废上一会话挂起的 isLifting 解锁
        isLifting = true
        draggingId = id
        lastGestureActivity = Date()
        sessionBaseline = baseline
        order = baseline
        fromIndex = index
        currentIndex = index
        anchor = .zero
        dragTranslation = .zero
        didDrag = false
    }

    /// 拖动跟手：位移 → 目标格换位（其余格由 order 变化驱动让位动画）
    func dragMoved(translation: CGSize) {
        guard let draggedId = draggingId, var liveOrder = order else { return }
        lastGestureActivity = Date()

        // 越过阈值后进入拖动语义（此后松手=落位，不再触发打开管理页）
        if !didDrag {
            guard abs(translation.width) > CategoryGridReorderFeel.dragMinimumDistance
                    || abs(translation.height) > CategoryGridReorderFeel.dragMinimumDistance else { return }
            didDrag = true
        }

        // 手指下方的格位 = 起始格位 + 手指总位移（四舍五入到最近格位）
        let target = Self.targetIndex(
            fromIndex: fromIndex,
            offset: translation,
            step: step,
            count: liveOrder.count
        )
        if target != currentIndex {
            liveOrder.remove(at: currentIndex)
            liveOrder.insert(draggedId, at: target)
            order = liveOrder
            currentIndex = target
            // 锚点 = 起始格位到当前格位的位移；被拖格视觉偏移 = 手指位移 − 锚点（换位瞬间不跳变）
            anchor = Self.slotOffset(from: fromIndex, to: target, step: step)
            HapticManager.selection()
        }

        dragTranslation = CGSize(
            width: translation.width - anchor.width,
            height: translation.height - anchor.height
        )
    }

    /// 松手收尾（幂等：Drag.onEnded 与 @GestureState 复位兜底都会调，先到者生效）：
    /// 未拖动 = 打开分类管理页；拖动过且顺序有变 = 落位持久化
    func dragEnded() {
        guard let draggedId = draggingId else { return }
        lastGestureActivity = Date()

        let shouldOpenManagement = !didDrag
        let finalOrder = order
        let changed = finalOrder != nil && finalOrder != sessionBaseline

        withAnimation(CategoryGridReorderFeel.settleSpring) {
            draggingId = nil
            dragTranslation = .zero
            order = nil
        }
        // 防误触锁定延迟解除（同 runloop 清会让格点击 tap 放行，习惯模块真机复现过）
        scheduleLiftClear()

        if shouldOpenManagement {
            onOpenManagement?()
        } else if changed, let finalOrder {
            onCommit?(finalOrder, draggedId)
        }
    }

    /// 手势结束兜底（格内 @GestureState 复位信号）：onEnded 丢失/系统取消时仍能收尾
    func gestureDidFinish(id: UUID) {
        guard draggingId == id else { return }
        dragEnded()
    }

    /// 取消会话不落库（切 Tab / 下钻返回 / 格销毁等场景由宿主调用）
    func cancelDrag() {
        guard draggingId != nil || isLifting else { return }
        lastGestureActivity = Date()
        withAnimation(CategoryGridReorderFeel.settleSpring) {
            draggingId = nil
            dragTranslation = .zero
            order = nil
        }
        scheduleLiftClear()
    }

    /// isLifting 延迟解锁（代数令牌防陈旧闭包误清新会话）
    private func scheduleLiftClear() {
        liftClearGeneration += 1
        let generation = liftClearGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + CategoryGridReorderFeel.interactionLockWindow) { [weak self] in
            guard let self, self.liftClearGeneration == generation else { return }
            self.isLifting = false
        }
    }

    // MARK: - 网格几何（纯函数，单测直接覆盖）

    /// 换位步长：一格宽 + 列距 / 一格高 + 行距
    private var step: CGSize {
        CGSize(
            width: columnWidth + CategoryGridReorderFeel.columnSpacing,
            height: cellHeight + CategoryGridReorderFeel.rowSpacing
        )
    }

    /// 拖拽偏移（相对起始格位）→ 目标格 index：四舍五入到最近格位，越界夹到 [0, count-1]
    static func targetIndex(fromIndex: Int, offset: CGSize, step: CGSize, count: Int) -> Int {
        let columns = CategoryGridReorderFeel.columns
        let col = fromIndex % columns + Int((offset.width / step.width).rounded())
        let row = fromIndex / columns + Int((offset.height / step.height).rounded())
        let clampedCol = min(max(col, 0), columns - 1)
        return min(max(row * columns + clampedCol, 0), count - 1)
    }

    /// 起始格位 → 目标格位的几何位移（换位后锚点吸附，跟手偏移不跳变）
    static func slotOffset(from fromIndex: Int, to target: Int, step: CGSize) -> CGSize {
        let columns = CategoryGridReorderFeel.columns
        return CGSize(
            width: CGFloat(target % columns - fromIndex % columns) * step.width,
            height: CGFloat(target / columns - fromIndex / columns) * step.height
        )
    }

    // MARK: - 落库完整序

    /// 宫格会话序（可见格）在前，未参与会话的同层行（如宫格不显示的 isSystem 一级「余额调整」）
    /// 按现有用户序追加尾部——FinanceRepository.reorderCategories 校验的是同层全集，
    /// 只传可见格会被判「分类已变化」拒绝；iCloud 同 id 副本行只计一次
    static func fullSiblingOrder(sessionIds: [UUID], siblings: [Category]) -> [UUID] {
        let sessionSet = Set(sessionIds)
        var seen = Set<UUID>()
        let hiddenIds = siblings
            .filter { !sessionSet.contains($0.id) }
            .sorted(by: Category.precedesInUserOrder)
            .compactMap { seen.insert($0.id).inserted ? $0.id : nil }
        return sessionIds + hiddenIds
    }

    // MARK: - 测试钩子

    /// 测试专用：把会话活动时刻回拨（模拟手势回调彻底丢失后的时间流逝）
    func test_backdateGestureActivity(by interval: TimeInterval) {
        lastGestureActivity = lastGestureActivity?.addingTimeInterval(-interval)
    }
}

// MARK: - 可排序分类格

/// 宫格分类格：Button 承担点击（下钻/选中），长按达成后才进入排序。
/// 被拖时：内容放大 1.17 + 投影 + 跟手位移，原网格位留虚线占位（图标恒 48pt，无尺寸跳变）
struct ReorderableCategoryCell: View {
    let category: Category
    let iconColor: Color
    let isSelected: Bool
    @ObservedObject var model: CategoryGridReorderModel
    /// 普通点击（会话活跃时被 admitInteraction 拦下）
    let onTap: () -> Void
    /// 任何点击先执行（键盘状态机：点分类格收计算键盘，长按也算交互）
    let onInteraction: () -> Void

    #if !canImport(UIKit)
    /// 排序手势进行中（长按达成后为 true）；手势结束/取消时 SwiftUI 必复位——收尾兜底信号
    @GestureState private var isReorderGestureActive = false
    #endif

    #if canImport(UIKit)
    var body: some View {
        // Button 保留键盘与辅助功能激活入口，格内触摸交给同一组 UIKit 手势。
        categoryButton
            .overlay {
                CategoryReorderTouchSurface(
                    categoryID: category.id,
                    model: model,
                    onLift: onInteraction,
                    onTap: selectCategory
                )
                .accessibilityHidden(true)
            }
    }
    #else
    var body: some View {
        categoryButton
            .simultaneousGesture(reorderGesture)
            .onChange(of: isReorderGestureActive) { _, isActive in
                if !isActive {
                    model.gestureDidFinish(id: category.id)
                }
            }
    }
    #endif

    private func selectCategory() {
        onInteraction()
        guard model.admitInteraction() else { return }
        onTap()
    }

    private var categoryButton: some View {
        let isDragging = model.draggingId == category.id

        return Button {
            #if !canImport(UIKit)
            // 本格持有会话时收到的点击 = 这次长按触摸的抬手（Button 与手势回调先后不定）：
            // 按松手收尾（未拖=开管理页 / 拖过=落位），绝不当普通点击——
            // 否则「长按后按住不动超过陈旧窗口再松手」会被陈旧自愈放行成下钻/选中
            if model.draggingId == category.id {
                onInteraction()
                model.dragEnded()
                return
            }
            #endif
            selectCategory()
        } label: {
            ZStack {
                if isDragging {
                    placeholder
                }
                content(isDragging: isDragging)
            }
            .holoRowHitArea(alignment: .center)
        }
        .buttonStyle(.plain)
        // 格销毁（分类被删/切视图）时手势随之消失、回调不会再来——正被拖的格就地取消会话
        .onDisappear {
            if model.draggingId == category.id {
                model.cancelDrag()
            }
        }
    }

    /// 原位虚线占位（被拖格浮走后留在网格位上）
    private var placeholder: some View {
        VStack(spacing: 6) {
            Circle()
                .strokeBorder(
                    iconColor.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
                .background(Circle().fill(iconColor.opacity(0.05)))
                .frame(width: 48, height: 48)
            Text(category.name)
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                .lineLimit(1)
        }
    }

    private func content(isDragging: Bool) -> some View {
        VStack(spacing: 6) {
            CategoryIconBadge(iconName: category.icon, color: iconColor, diameter: 48, isSelected: isSelected)
            Text(category.name)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)
                .lineLimit(1)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            model.noteCellHeight(height)
        }
        .scaleEffect(isDragging ? CategoryGridReorderFeel.liftScale : 1)
        .shadow(
            color: isDragging ? .black.opacity(CategoryGridReorderFeel.liftShadowOpacity) : .clear,
            radius: isDragging ? CategoryGridReorderFeel.liftShadowRadius : 0,
            x: 0,
            y: isDragging ? 6 : 0
        )
        .offset(isDragging ? model.dragTranslation : .zero)
    }

    #if !canImport(UIKit)
    /// 长按+拖拽组合手势（回调挂组成手势上，同习惯模块）：
    /// Drag 最小距离 0——长按达成后立即接管触点，原地松手也能走到 onEnded；
    /// 拖动语义由模型按 dragMinimumDistance 判定
    private var reorderGesture: some Gesture {
        let longPress = LongPressGesture(minimumDuration: CategoryGridReorderFeel.liftDelay)
            .onEnded { _ in
                model.beginPress(id: category.id)
            }
        let drag = DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                model.dragMoved(translation: value.translation)
            }
            .onEnded { _ in
                model.dragEnded()
            }
        return longPress.sequenced(before: drag)
            .updating($isReorderGestureActive) { value, state, _ in
                if case .second(true, _) = value {
                    state = true
                }
            }
    }
    #endif
}

#if canImport(UIKit)
/// 给格内的轻点和长按共用一处原生触摸入口。手指先移动时两个识别器都会让位给滚动；
/// 原地按够时间才由长按接管，按住移动和纯轻点都不会触发对方的动作。
private struct CategoryReorderTouchSurface: UIViewRepresentable {
    let categoryID: UUID
    let model: CategoryGridReorderModel
    let onLift: () -> Void
    let onTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePress(_:)))
        press.minimumPressDuration = CategoryGridReorderFeel.liftDelay
        press.allowableMovement = 10
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.require(toFail: press)
        view.addGestureRecognizer(press)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: CategoryReorderTouchSurface
        private var origin: CGPoint?

        init(_ parent: CategoryReorderTouchSurface) {
            self.parent = parent
        }

        @objc func handleTap() {
            parent.onTap()
        }

        @objc func handlePress(_ press: UILongPressGestureRecognizer) {
            let model = parent.model
            // 用窗口坐标，避免格子跟手或换位时把自身位移算进手指位移。
            let location = press.location(in: nil)

            switch press.state {
            case .began:
                model.beginPress(id: parent.categoryID)
                guard model.draggingId == parent.categoryID else { return }
                origin = location
                parent.onLift()
            case .changed, .ended:
                guard let origin, model.draggingId == parent.categoryID else { return }
                model.dragMoved(translation: CGSize(width: location.x - origin.x, height: location.y - origin.y))
                if press.state == .ended {
                    self.origin = nil
                    model.dragEnded()
                }
            case .cancelled, .failed:
                defer { origin = nil }
                if origin != nil, model.draggingId == parent.categoryID {
                    model.cancelDrag()
                }
            default:
                break
            }
        }
    }
}
#endif
