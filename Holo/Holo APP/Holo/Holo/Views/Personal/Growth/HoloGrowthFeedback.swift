// 里程碑轻提示只占自身热区，不创建窗口、不拦截整屏、不抢输入焦点。
import SwiftUI

struct HoloGrowthFeedbackModifier: ViewModifier {
    @ObservedObject private var service = HoloGrowthService.shared
    @State private var selectedEvent: HoloGrowthMilestone?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let event = service.celebration, scenePhase == .active {
                    HoloGrowthFeedbackBanner(event: event, onOpen: {
                        selectedEvent = event
                        service.dismissCelebration()
                    }, onClose: { service.dismissCelebration() })
                    .padding(.horizontal, HoloSpacing.page)
                    .padding(.top, 8)
                    .holoContentColumn(paintsBackground: false)
                    .transition(.opacity)
                    .task(id: event.id) {
                        try? await Task.sleep(for: .seconds(8))
                        guard !Task.isCancelled, service.celebration?.id == event.id else { return }
                        service.dismissCelebration()
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: service.celebration?.id)
            .sheet(item: $selectedEvent) { event in NavigationStack { HoloGrowthMilestoneView(event: event) } }
    }
}

private struct HoloGrowthFeedbackBanner: View {
    let event: HoloGrowthMilestone
    let onOpen: () -> Void
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: event.metric.icon).foregroundStyle(Color.holoToolAction)
                    Text(event.title).holoText(.supporting).foregroundStyle(Color.holoToolText)
                    Spacer(minLength: 0)
                    Text("看看").holoText(.metadata).foregroundStyle(Color.holoToolAction)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.holoToolTextSecondary)
            .accessibilityLabel("关闭里程碑提醒")
        }
        .padding(.leading, 16)
        .padding(.vertical, 6)
        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.holoToolBorder, lineWidth: 0.5))
        .accessibilityIdentifier("growth.celebration")
    }
}
