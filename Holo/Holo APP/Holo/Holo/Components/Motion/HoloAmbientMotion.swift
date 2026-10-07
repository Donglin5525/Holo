import SwiftUI

/// 所有持续装饰共用的运行条件；静态图形仍保留，只有运动停下。
struct HoloContinuousMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.holoMotionSurfaceIsActive) private var surfaceActive
    @AppStorage(HoloMotionRollout.interactionKey) private var enabled = true

    var isActive: Bool { enabled && !reduceMotion && surfaceActive && scenePhase == .active }
}

private struct HoloRepeatingPhase<Value: Equatable>: ViewModifier {
    @Binding var phase: Value
    let start: Value
    let end: Value
    let animation: Animation
    let enabled: Bool
    var motion = HoloContinuousMotion()
    private var active: Bool { enabled && motion.isActive }

    func body(content: Content) -> some View {
        content
            .onAppear { synchronize() }
            .onChange(of: active) { _, _ in synchronize() }
            .onDisappear { reset() }
    }

    private func reset() {
        var transaction = SwiftUI.Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { phase = start }
    }

    private func synchronize() {
        reset()
        guard active else { return }
        withAnimation(animation) { phase = end }
    }
}

private struct HoloAmbientOpacity: ViewModifier {
    let dimmed: Double
    let duration: Double
    let delay: Double
    let enabled: Bool
    @State private var phase = false

    func body(content: Content) -> some View {
        content.opacity(phase ? dimmed : 1)
            .holoRepeatingPhase($phase, from: false, to: true,
                                animation: .easeInOut(duration: duration).delay(delay).repeatForever(autoreverses: true),
                                enabled: enabled)
    }
}

extension View {
    func holoRepeatingPhase<Value: Equatable>(_ phase: Binding<Value>, from: Value, to: Value,
                                               animation: Animation, enabled: Bool = true) -> some View {
        modifier(HoloRepeatingPhase(phase: phase, start: from, end: to, animation: animation, enabled: enabled))
    }

    /// 只应用于光标和图标叶节点，减少动态效果时始终可见。
    func holoAmbientOpacity(dimmed: Double = 0, duration: Double = 0.5,
                            delay: Double = 0, enabled: Bool = true) -> some View {
        modifier(HoloAmbientOpacity(dimmed: dimmed, duration: duration, delay: delay, enabled: enabled))
    }
}
