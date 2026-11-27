//
//  HabitLightDirector.swift
//  Holo
//
//  习惯完成「E 光归处」（2026-11-23 审美七项 P1）的事件导演：
//  HoloMotionFeedbackCenter 的完成事件取走即失，行内点亮与页面级飞行
//  不能各自 consume——由今天页这一层统一消费一次，再分发两路播放：
//
//  · ignitions      行内灯的点亮令牌（event.operationID）
//  · flights        正在飞的光点（坐标是起飞时的快照，飞行途中滚动允许轻微错位）
//  · pendingLanding 飞行未落地前压住页头对应小灯，落地（或兜底超时）后放行
//
//  光点往哪去由 flightPlan 决定：页头小灯看得见就飞向小灯；小灯被滚出视口就往上飞走、
//  在视口顶边前淡尽（2026-11-25 东林拍板：同一个动作，反馈不随滚动位置缩水）。
//  撤销打卡由页面调 cancel(habitId:)；App 进后台调 clearTransient()。
//  每日看板（KanbanHabitSection）的 .holoRecordArrival 保持不动：
//  两个界面不同时可见，isVisible 门控保证只有可见的一方消费。
//

import Combine
import SwiftUI

// MARK: - 坐标系与起点 / 终点上报

/// 今天页两个命名坐标系：viewport = ScrollView 视口（页头可见性判断），
/// content = 滚动内容（光点起终点与飞行层共用，滚动时同系不错位）。
enum HabitTodayLightSpace {
    static let viewport = "habitTodayViewport"
    static let content = "habitToday"
}

/// 行内主操作按钮（灯 / ＋ / 记录）中心点上报：habitId → content 坐标系坐标
struct HabitLampOriginKey: PreferenceKey {
    static var defaultValue: [UUID: CGPoint] { [:] }
    static func reduce(value: inout [UUID: CGPoint], nextValue: () -> [UUID: CGPoint]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 页头小灯中心点上报（同 content 坐标系）
struct HabitLampDestinationKey: PreferenceKey {
    static var defaultValue: [UUID: CGPoint] { [:] }
    static func reduce(value: inout [UUID: CGPoint], nextValue: () -> [UUID: CGPoint]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 「今日的灯」那排小灯是否完整露在视口里。页头被 LazyVStack 回收、
/// 或本来就没画小灯（没有好习惯 / 超过上限只留文字）时没有上报 = false
struct HabitTallyVisibleKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// 滚动内容顶边在视口里的纵向位置（没滚时 ≥ 0，往下滚为负）。
/// 值必须可选、合并时跳过没设过这个键的节点：合并时列表里别的节点会带着默认值一起进来，
/// 非可选 + 「取下一个」的写法会被冲回 0——量到了却永远送不到（2026-11-25 模拟器实拍：
/// 量到 4 → −364 共 55 次，收数端只收到一次 0，光点因此飞过可见范围被切）
struct HabitContentTopKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// 把当前视图中心上报为光点起飞起点（habitToday 坐标系；不可见行不渲染即无起点）
    func habitLampOrigin(id: UUID) -> some View {
        background(
            GeometryReader { geo in
                let frame = geo.frame(in: .named(HabitTodayLightSpace.content))
                Color.clear.preference(
                    key: HabitLampOriginKey.self,
                    value: [id: CGPoint(x: frame.midX, y: frame.midY)]
                )
            }
        )
    }
}

// MARK: - 飞行模型

/// 光点往哪去
enum HabitLightFlightKind {
    /// 飞到页头小灯：末段才淡出，落点就是小灯
    case toTally
    /// 往上飞走（小灯被滚出视口）：后半程渐淡，在视口顶边前淡尽
    case upward

    /// 淡出起点（飞行进度 0…1，之前的路程全亮）
    var fadeStart: Double {
        switch self {
        case .toTally: return 0.9
        case .upward: return 0.5
        }
    }
}

/// 一次飞行的起终点（起飞时的坐标快照）与去向
struct HabitLightFlightPlan: Equatable {
    let start: CGPoint
    let end: CGPoint
    var kind: HabitLightFlightKind = .toTally
}

/// 正在飞的光点
struct HabitLightFlight: Identifiable {
    let id: UUID
    let habitId: UUID
    let color: Color
    let start: CGPoint
    let end: CGPoint
    var kind: HabitLightFlightKind = .toTally
}

/// 光点路径几何：二次贝塞尔 + easeInOut（纯函数，供飞行层与测试共用）
nonisolated enum HabitLightGeometry {
    /// 控制点相对起终点中点的偏移（向左、向上）
    static let bendLeft: CGFloat = 40
    static let bendUp: CGFloat = 30

    /// 往上飞走时光点在视口顶边下方多远淡尽：光点半径 + 模糊 + 余量。
    /// 滚动区会把内容切在那条边上，留出这段距离，边上就不会出现被切一半的光点
    static let topFadeMargin: CGFloat = 18

    static func controlPoint(from start: CGPoint, to end: CGPoint) -> CGPoint {
        CGPoint(x: (start.x + end.x) / 2 - bendLeft,
                y: (start.y + end.y) / 2 - bendUp)
    }

    /// 二次贝塞尔取点（t ∈ 0…1）
    static func point(from start: CGPoint, to end: CGPoint, t: Double) -> CGPoint {
        let c = controlPoint(from: start, to: end)
        let mt = 1 - t
        return CGPoint(x: mt * mt * start.x + 2 * mt * t * c.x + t * t * end.x,
                       y: mt * mt * start.y + 2 * mt * t * c.y + t * t * end.y)
    }

    /// 标准 easeInOut 曲线（0→0，0.5→0.5，1→1；越界截断）
    static func easeInOut(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t)
    }

    /// 小灯排完整露在视口里 = 它的顶边已经进了视口。只剩一条边也算滚出去了：
    /// 这时飞过去，落点几乎看不见，和没飞一样
    static func tallyIsFullyVisible(topInViewport: CGFloat) -> Bool {
        topInViewport >= 0
    }

    /// 往上飞走的终点：横向不动，纵向停在视口顶边下方 topFadeMargin 处。
    /// 灯离顶边不足这段距离时就地淡尽（不往下走）
    static func upwardEnd(from start: CGPoint, contentTopInViewport: CGFloat) -> CGPoint {
        CGPoint(x: start.x, y: min(-contentTopInViewport + topFadeMargin, start.y))
    }

    /// 淡出：fadeStart 之前全亮，之后线性淡到 0（越界截断）
    static func opacity(progress: Double, fadeStart: Double) -> Double {
        guard progress >= fadeStart else { return 1 }
        let fade = (progress - fadeStart) / (1 - fadeStart)
        return max(1 - fade, 0)
    }
}

// MARK: - 导演

/// 起飞那一刻页面的位置（视口坐标系）。随滚动每帧写入，但不发布——发布会让整页每个滚动帧重绘
struct HabitLightStage: Equatable {
    /// 「今日的灯」那排小灯完整露在视口里
    var tallyIsFullyVisible = false
    /// 滚动内容顶边在视口里的纵向位置：没滚时 ≥ 0，往下滚为负
    var contentTopInViewport: CGFloat = 0
    /// 「今日的灯」在 content 坐标系中的静态顶边 Y（iOS 18+ onScrollGeometryChange 推导可见性用，不随滚动变）
    var tallyTopInContent: CGFloat? = nil
    /// 行内主操作按钮中心（habitToday 坐标系；不发布，避免滚动/布局微调触发整页重绘）
    var rowLampOrigins: [UUID: CGPoint] = [:]
    /// 页头小灯中心（同坐标系；不发布）
    var headerLampCenters: [UUID: CGPoint] = [:]
}

/// 飞行光点独立发布源：让光点起飞/落地只刷新飞行覆盖层，不打穿外层 HabitTodayView 全表重绘
@MainActor
final class HabitLightFlightStore: ObservableObject {
    @Published var flights: [HabitLightFlight] = []
}

@MainActor
final class HabitLightDirector: ObservableObject {

    /// 落地兜底：光点起飞后无论是否落地，到时都放行页头小灯（默认 1.2s）
    private static let defaultLandingTimeout: TimeInterval = 1.2
    /// 点亮令牌的生命周期：动画播完后即清空，行被 LazyVStack 回收重挂时不重播
    /// （光晕时长 + 收尾余量）
    private static let ignitionLifetime: TimeInterval = HoloAnimation.lampHaloDuration + 0.1

    /// 行内点亮令牌：habitId → 本次点亮的 token
    @Published private(set) var ignitions: [UUID: UUID] = [:]
    /// 飞行光点独立存储（不直接 @Published 在导演上，避免起飞/落地重绘整张习惯列表）
    let flightStore = HabitLightFlightStore()
    /// 正在飞的光点（兼容既有读法与单测）
    var flights: [HabitLightFlight] { flightStore.flights }
    /// 飞行未落地前，页头对应小灯保持未亮
    @Published private(set) var pendingLanding: Set<UUID> = []

    /// 起飞决策用的页面位置（由今天页随布局写入，不发布）
    var stage = HabitLightStage()

    /// 起飞延迟与兜底时长可注入（测试用极短值，不真等 1.2 秒）
    private let flightDelay: TimeInterval
    private let landingTimeout: TimeInterval
    private var landingTasks: [UUID: Task<Void, Never>] = [:]

    init(flightDelay: TimeInterval = HoloAnimation.lightFlightDelay,
         landingTimeout: TimeInterval = HabitLightDirector.defaultLandingTimeout) {
        self.flightDelay = flightDelay
        self.landingTimeout = landingTimeout
    }

    /// 起飞决策：小灯排完整露在视口里 → 飞到小灯；被滚出视口或只剩一条边 → 往上飞走。
    /// 没有小灯排（没有好习惯 / 超过上限只留文字）、拿不到起点，
    /// 或小灯可见却拿不到它的位置 → 不飞。
    static func flightPlan(start: CGPoint?, destination: CGPoint?, tallyCount: Int,
                           stage: HabitLightStage) -> HabitLightFlightPlan? {
        guard let start, (1...HabitTodayLightsMetrics.maxLampCount).contains(tallyCount) else { return nil }
        guard stage.tallyIsFullyVisible else {
            return HabitLightFlightPlan(
                start: start,
                end: HabitLightGeometry.upwardEnd(from: start, contentTopInViewport: stage.contentTopInViewport),
                kind: .upward)
        }
        guard let destination else { return nil }
        return HabitLightFlightPlan(start: start, end: destination)
    }

    /// 消费到一次完成事件：行内立即点亮；给了飞行计划就**立刻**占住页头小灯、延迟起飞，
    /// 没给（没有小灯排 / 起点拿不到 / 动效关闭）就只点亮不飞。
    func handle(event: HoloMotionEvent, habitId: UUID, color: Color, flight: HabitLightFlightPlan?) {
        ignitions[habitId] = event.operationID
        scheduleIgnitionExpiry(event: event, habitId: habitId)
        cancelLandingTask(habitId)
        guard let flight else { return }
        // 一拿到事件就压住页头小灯：若等起飞才压，点亮到起飞之间小灯会「先亮一下再熄灭」
        // （模拟器连拍实抓），与「飞行未落地前小灯保持未亮」的规格不符
        pendingLanding.insert(habitId)
        let flightID = UUID()
        let delay = flightDelay
        let timeout = landingTimeout
        landingTasks[habitId] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.flightStore.flights.append(HabitLightFlight(id: flightID, habitId: habitId, color: color,
                                                 start: flight.start, end: flight.end, kind: flight.kind))
            // 兜底：飞行视图被回收 / 回调丢失时，页头小灯也不能永远不亮
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self.settle(habitId: habitId, flightID: flightID)
        }
    }

    /// 落地：移除飞行、放行页头小灯（页头随后自播落地轻跳）
    func land(_ flightID: UUID) {
        guard let flight = flightStore.flights.first(where: { $0.id == flightID }) else { return }
        cancelLandingTask(flight.habitId)
        settle(habitId: flight.habitId, flightID: flightID)
    }

    /// 撤销打卡：点火、飞行、页头占位全部清理
    func cancel(habitId: UUID) {
        ignitions[habitId] = nil
        cancelLandingTask(habitId)
        flightStore.flights.removeAll { $0.habitId == habitId }
        pendingLanding.remove(habitId)
    }

    /// App 进后台：清掉进行中的飞行与占位（事件本体由 Motion 中心照常丢弃）
    func clearTransient() {
        landingTasks.values.forEach { $0.cancel() }
        landingTasks.removeAll()
        flightStore.flights.removeAll()
        pendingLanding.removeAll()
    }

    private func settle(habitId: UUID, flightID: UUID) {
        flightStore.flights.removeAll { $0.id == flightID }
        pendingLanding.remove(habitId)
    }

    /// 点亮令牌到期即清：非 nil 窗口 = 「正在播」。灯视图挂载时带着非 nil 令牌
    /// 即播（首次完成的胶囊→灯切换正属于这种挂载）；窗口外回收重挂只见 nil，不重播
    private func scheduleIgnitionExpiry(event: HoloMotionEvent, habitId: UUID) {
        let lifetime = HabitLightDirector.ignitionLifetime
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(lifetime)) } catch { return }
            guard let self else { return }
            if self.ignitions[habitId] == event.operationID {
                self.ignitions[habitId] = nil
            }
        }
    }

    private func cancelLandingTask(_ habitId: UUID) {
        landingTasks[habitId]?.cancel()
        landingTasks[habitId] = nil
    }
}

// MARK: - 飞行层

/// 光点飞行层：独立观察 flightStore，起飞/落地不触发外层习惯列表重绘，不参与命中
struct HabitLightFlightOverlay: View {
    @ObservedObject var store: HabitLightFlightStore
    let onLand: (UUID) -> Void

    var body: some View {
        HabitLightFlightLayer(flights: store.flights, onLand: onLand)
    }
}

/// 光点飞行层：盖在滚动内容上（坐标同系，飞行途中滚动不错位），不参与命中
struct HabitLightFlightLayer: View {
    let flights: [HabitLightFlight]
    let onLand: (UUID) -> Void

    var body: some View {
        ForEach(flights) { flight in
            HabitLightFlightDot(flight: flight, onLand: onLand)
        }
        .allowsHitTesting(false)
    }
}

/// 飞行光点的局部尺寸与节拍
private enum HabitLightFlightMetrics {
    /// 稍放大直径并用柔和径向渐变替代每帧实时 .blur 离屏滤镜，120Hz 全程零离屏模糊开销
    static let dotDiameter: CGFloat = 12
    /// 落地回调相对动画时长的余量（保证最后一帧已画完）
    static let landGrace: TimeInterval = 0.05
}

/// 单颗光点：出现即起飞，按真实时间沿贝塞尔曲线飞 0.7 秒，淡出后回调落地。
/// 何时开始淡由去向决定（HabitLightFlightKind.fadeStart）：飞向小灯的末段才淡，往上飞走的后半程渐淡。
/// 用 TimelineView 按时间推进，不用 KeyframeAnimator——关键帧动画器在这种「插入即起播」的
/// 场景下实测停在初值不动（模拟器 UI 自动化连拍逐帧量像素：光点起飞后一直停在灯芯上）。
private struct HabitLightFlightDot: View {
    let flight: HabitLightFlight
    let onLand: (UUID) -> Void
    /// 起飞时刻（视图首次插入时取一次）
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let progress = progress(at: context.date)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white, flight.color.opacity(0.95), flight.color.opacity(0.35), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: HabitLightFlightMetrics.dotDiameter / 2
                    )
                )
                .frame(width: HabitLightFlightMetrics.dotDiameter,
                       height: HabitLightFlightMetrics.dotDiameter)
                .position(position(at: progress))
                .opacity(opacity(at: progress))
        }
        .task {
            try? await Task.sleep(
                for: .seconds(HoloAnimation.lightFlightDuration + HabitLightFlightMetrics.landGrace))
            onLand(flight.id)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 0…1 的飞行进度（按真实时间，越界截断）
    private func progress(at date: Date) -> Double {
        let raw = date.timeIntervalSince(startedAt) / HoloAnimation.lightFlightDuration
        return raw.isNaN ? 0 : min(max(raw, 0), 1)
    }

    /// 进度（0…1）→ 缓动后的贝塞尔位置
    private func position(at progress: Double) -> CGPoint {
        HabitLightGeometry.point(from: flight.start, to: flight.end,
                                 t: HabitLightGeometry.easeInOut(progress))
    }

    private func opacity(at progress: Double) -> Double {
        HabitLightGeometry.opacity(progress: progress, fadeStart: flight.kind.fadeStart)
    }
}

// MARK: - 滚动几何追踪（iOS 18+ 走 onScrollGeometryChange / onGeometryChange，消除每帧偏好归约）

/// iOS 18+ 无需在滚动内容上挂 GeometryReader；仅 iOS 17 兜底使用 HabitContentTopKey。
struct HabitLegacyContentTopReporter: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
        } else {
            content.background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: HabitContentTopKey.self,
                        value: geo.frame(in: .named(HabitTodayLightSpace.viewport)).minY
                    )
                }
            }
        }
    }
}

/// 挂在 ScrollView 上，iOS 18+ 直接从滚动几何同步 contentTopInViewport 与页头小灯可见性，
/// 彻底消除滚动每帧的 GeometryReader + PreferenceKey 整树归约。
struct HabitScrollOffsetTracker: ViewModifier {
    let director: HabitLightDirector

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geo in
                -geo.visibleRect.minY
            } action: { _, contentTop in
                director.stage.contentTopInViewport = contentTop
                if let tallyTop = director.stage.tallyTopInContent {
                    director.stage.tallyIsFullyVisible = HabitLightGeometry.tallyIsFullyVisible(
                        topInViewport: contentTop + tallyTop
                    )
                } else {
                    director.stage.tallyIsFullyVisible = false
                }
            }
        } else {
            content
        }
    }
}

/// 挂在页头「今日的灯」小灯排上：iOS 18+ 只在 content 坐标系测一次静态 minY（滚动不变），
/// 避免每帧以 viewport 坐标系重算。
struct HabitTallyGeometryReporter: ViewModifier {
    let director: HabitLightDirector

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(HabitTodayLightSpace.content)).minY
                } action: { minY in
                    director.stage.tallyTopInContent = minY
                    director.stage.tallyIsFullyVisible = HabitLightGeometry.tallyIsFullyVisible(
                        topInViewport: director.stage.contentTopInViewport + minY
                    )
                }
                .onDisappear {
                    director.stage.tallyTopInContent = nil
                    director.stage.tallyIsFullyVisible = false
                }
        } else {
            content.background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: HabitTallyVisibleKey.self,
                        value: HabitLightGeometry.tallyIsFullyVisible(
                            topInViewport: geo.frame(in: .named(HabitTodayLightSpace.viewport)).minY
                        )
                    )
                }
            )
        }
    }
}
