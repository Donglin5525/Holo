import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import Foundation
import Combine

extension Notification.Name {
    /// 手动记账保存成功的来源标记，云同步和历史刷新不会发送。
    static let holoManualFinanceRecordSaved = Notification.Name("holoManualFinanceRecordSaved")
}

@MainActor
final class HoloMotionFeedbackCenter: ObservableObject {
    static let shared = HoloMotionFeedbackCenter()
    @Published private(set) var generations: [HoloMotionSubject: UUID] = [:]
    /// 按目标 subject 精准投递的事件通道：让列表行无需 @ObservedObject 订阅整本 generations 字典，
    /// 避免任意一条记录保存时打穿全 App 所有常驻列表的所有行。
    let subjectPublisher = PassthroughSubject<HoloMotionSubject, Never>()
    private var responseOrder: [HoloMotionSubject] = []
    private var ledger = HoloMotionEventLedger()
    private static let habitDayKey = "holo.motion.habitResponseDay"
    private var habitPolicy = HoloHabitMotionDayPolicy()
    private var backgroundObserver: AnyCancellable?

    private init() {
        // 仅保存本机展示次数，重启后撤销再勾选也不会重复庆祝；不参与习惯业务数据。
        if let data = UserDefaults.standard.data(forKey: Self.habitDayKey),
           let policy = try? JSONDecoder().decode(HoloHabitMotionDayPolicy.self, from: data) {
            habitPolicy = policy
        }
        // 包括尚未挂载的列表行：离开前台即取消待播事件，返回时不补播。
        #if canImport(UIKit)
        let willResignActive = UIApplication.willResignActiveNotification
        #else
        let willResignActive = NSApplication.willResignActiveNotification
        #endif
        backgroundObserver = NotificationCenter.default.publisher(for: willResignActive)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.ledger.discardAll() }
            }
    }

    /// App 是否处于前台活跃（macOS 单窗口 App 视为恒活跃）
    private var isAppActive: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    func saved(_ id: UUID, domain: HoloMotionSubject.Domain, operationID: UUID = UUID()) {
        if domain == .finance, isAppActive {
            NotificationCenter.default.post(name: .holoManualFinanceRecordSaved, object: id)
        }
        let key = domain == .habit ? HoloMotionRollout.completionKey : HoloMotionRollout.recordKey
        guard HoloMotionPreferencePolicy.isEnabled(key),
              isAppActive else { return }
        ledger.record(HoloMotionEvent(operationID: operationID,
                                     subject: HoloMotionSubject(domain: domain, id: id),
                                     phase: .confirmed, occurredAt: Date()))
        advance(HoloMotionSubject(domain: domain, id: id))
    }

    /// 同一习惯当天只回应首次有效记录；撤销后再勾选不重复庆祝。
    func completedHabit(_ id: UUID) {
        guard habitPolicy.claim(id, at: Date()) else { return }
        if let data = try? JSONEncoder().encode(habitPolicy) {
            UserDefaults.standard.set(data, forKey: Self.habitDayKey)
        }
        saved(id, domain: .habit)
    }

    func consume(_ subject: HoloMotionSubject, enabled: Bool, isVisible: Bool) -> HoloMotionEvent? {
        ledger.consume(subject, now: Date(), enabled: enabled, isVisible: isVisible)
    }

    func discard(_ subject: HoloMotionSubject) {
        ledger.discard(subject)
    }

    func cancelHabitResponse(_ id: UUID) {
        ledger.discard(HoloMotionSubject(domain: .habit, id: id))
        advance(HoloMotionSubject(domain: .habit, id: id))
    }

    private func advance(_ subject: HoloMotionSubject) {
        responseOrder.removeAll { $0 == subject }
        responseOrder.append(subject)
        generations[subject] = UUID()
        if responseOrder.count > 128 { generations[responseOrder.removeFirst()] = nil }
        subjectPublisher.send(subject)
    }
}

private struct HoloMotionSurfaceActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 父容器有编辑弹层时关闭，回到列表后再播放本次保存反馈。
    var holoMotionSurfaceIsActive: Bool {
        get { self[HoloMotionSurfaceActiveKey.self] }
        set { self[HoloMotionSurfaceActiveKey.self] = newValue }
    }
}

/// 所有暖光都是无命中的局部装饰；正文与金额从始至终显示真实结果。
/// 使用状态动画驱动而非 KeyframeAnimator（视图插入即播场景下 KeyframeAnimator 会停在初值 0，见设计规范 §7）。
private struct HoloLightResponse: View {
    let completion: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
            .strokeBorder(Color.holoPrimary.opacity(Double(1 - progress) * 0.38), lineWidth: 1.5)
            .scaleEffect(completion ? 1 + progress * HoloAnimation.completionGlowExpansion : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(completion ? HoloAnimation.completionGlow : HoloAnimation.recordSettle) {
                    progress = 1
                }
            }
    }
}

private struct HoloRecordArrival: ViewModifier {
    let subject: HoloMotionSubject
    let surfaceActive: Bool
    @Environment(\.holoMotionSurfaceIsActive) private var parentActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(HoloMotionRollout.recordKey) private var recordEnabled = true
    @AppStorage(HoloMotionRollout.completionKey) private var completionEnabled = true
    @State private var arrivalGeneration: UUID? = nil
    @State private var showing = false
    @State private var responseID: UUID?

    private var enabled: Bool { subject.domain == .habit ? completionEnabled : recordEnabled }
    private struct Delivery: Hashable {
        let subject: HoloMotionSubject
        let generation: UUID?
        let enabled: Bool
        let visible: Bool
        let foreground: Bool
        let reduceMotion: Bool
    }

    func body(content: Content) -> some View {
        let center = HoloMotionFeedbackCenter.shared
        let effectiveGeneration = arrivalGeneration ?? center.generations[subject]
        return content
            .overlay {
                if showing {
                    HoloLightResponse(completion: subject.domain == .habit)
                        .id(responseID)
                }
            }
            .onReceive(center.subjectPublisher) { changed in
                guard changed == subject else { return }
                arrivalGeneration = center.generations[subject]
            }
            .task(id: Delivery(subject: subject, generation: effectiveGeneration, enabled: enabled,
                               visible: parentActive && surfaceActive, foreground: scenePhase == .active,
                               reduceMotion: reduceMotion)) {
                // 绝大多数日常滑动行无待播事件：直接短路，绝不写 @State 或启动 0.28s 睡眠任务
                guard effectiveGeneration != nil else {
                    if showing { showing = false }
                    return
                }
                if showing { showing = false }
                // 后台与关闭动态效果直接丢弃；只有短时编辑遮挡可以等待返回列表。
                guard enabled, !reduceMotion, scenePhase == .active else {
                    center.discard(subject)
                    return
                }
                guard parentActive, surfaceActive else { return }
                // 等弹层退出，避免光痕在被遮住的列表里提前播完。
                do { try await Task.sleep(for: .seconds(HoloScreenTransitionMetrics.duration)) }
                catch { return }
                guard let event = center.consume(subject, enabled: enabled, isVisible: true) else { return }
                responseID = event.operationID
                showing = true
                let completion = subject.domain == .habit
                do { try await Task.sleep(for: .seconds(completion ? HoloAnimation.completionGlowDuration : HoloAnimation.recordSettleDuration)) }
                catch { showing = false; return }
                showing = false
            }
    }
}

/// 日回放仅在明确打开一天时展开，刷新、筛选与连续滚动不重新播放。
@MainActor
final class HoloReplayRevealSession: ObservableObject {
    private var ledger = HoloReplayMotionLedger()

    func cancel(_ requestID: UUID) { ledger.cancel(requestID) }
    func claim(_ requestID: UUID, item: Int, requestedAt: Date) -> Bool {
        ledger.claim(requestID, item: item, requestedAt: requestedAt, now: Date())
    }
}

private struct HoloReplayReveal: ViewModifier {
    let requestID: UUID?
    let requestedAt: Date
    let item: Int
    let order: Int
    let session: HoloReplayRevealSession
    @Environment(\.holoMotionSurfaceIsActive) private var surfaceActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(HoloMotionRollout.replayKey) private var enabled = true
    @State private var revealed = true

    private struct Delivery: Hashable { let request: UUID?; let active: Bool }
    private var active: Bool { enabled && !reduceMotion && surfaceActive && scenePhase == .active }

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0.65)
            .offset(y: revealed ? 0 : HoloAnimation.replayOffset)
            .task(id: Delivery(request: requestID, active: active)) {
                revealed = true
                guard let requestID else { return }
                guard active else { session.cancel(requestID); return }
                guard session.claim(requestID, item: item, requestedAt: requestedAt) else { return }
                revealed = false
                do { try await Task.sleep(for: .seconds(HoloAnimation.replayDelay(order: order))) }
                catch { revealed = true; return }
                withAnimation(HoloAnimation.replayReveal) { revealed = true }
            }
            .onDisappear {
                revealed = true
                if let requestID { session.cancel(requestID) }
            }
    }
}

extension View {
    func holoRecordArrival(_ id: UUID, domain: HoloMotionSubject.Domain,
                           isActive: Bool = true) -> some View {
        modifier(HoloRecordArrival(subject: HoloMotionSubject(domain: domain, id: id), surfaceActive: isActive))
    }

    func holoReplayReveal(requestID: UUID?, requestedAt: Date, item: Int, order: Int, session: HoloReplayRevealSession) -> some View {
        modifier(HoloReplayReveal(requestID: requestID, requestedAt: requestedAt, item: item, order: order, session: session))
    }
}
