//
//  ScheduleCommonViews.swift
//  Holo
//
//  日程展示共用组件（今日看板/首页今日/任务页今日 三处复用）
//  - ScheduleSectionCard：区块容器（含全天日程折叠 + 定时日程列表）
//  - ScheduleRowCard：单条日程行（勾完成 + 点击详情）
//  - ScheduleDetailSheet：日程详情（去系统日历查看）
//

import SwiftUI
import EventKit
import EventKitUI

// MARK: - 接入引导条（未开启时出现在任务页/看板，原地发起授权，不必去设置页）

struct ScheduleOnboardingBar: View {
    @StateObject private var store = ScheduleStore.shared
    /// 用户点过 × 后永久不再出现（除非重装）
    @AppStorage("com.holo.schedule.onboardingDismissed") private var dismissed = false
    @State private var isStarting = false

    /// 权限被拒后的引导跳系统设置
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    var body: some View {
        if !dismissed {
            if !store.isEnabled {
                startBar
            } else if store.authorizationStatus == .denied || store.authorizationStatus == .restricted {
                deniedBar
            }
        }
    }

    private var startBar: some View {
        HStack(spacing: 0) {
            Button {
                guard !isStarting else { return }
                isStarting = true
                Task {
                    await store.enable()
                    isStarting = false
                    if store.authorizationStatus == .fullAccess {
                        HapticManager.success()
                    }
                }
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.holoPrimary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("接入系统日历")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("日程进入 Holo，AI 规划自动避开会议")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer(minLength: 8)

                    if isStarting {
                        ProgressView()
                    } else {
                        Text("开启")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.holoPrimaryDark)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.holoPrimary.opacity(0.15)))
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            dismissButton
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var deniedBar: some View {
        HStack(spacing: 0) {
            Button(action: openSystemSettings) {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.holoError)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("日历权限被拒绝")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                        Text("点击前往系统设置开启后即可使用")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12))
                        .foregroundColor(.holoPrimary)
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            dismissButton
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var dismissButton: some View {
        Button {
            dismissed = true
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.holoTextSecondary.opacity(0.7))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 带详情弹窗的日程区块（今日看板 / 任务页今日 共用包装；未开启时降级为接入引导条）

struct ScheduleSectionWithDetail: View {
    @State private var detailItem: ScheduleItem?

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            // 未开启/被拒：引导条；开启且今日有日程：日程区块（两者互斥，由各自内部条件控制）
            ScheduleOnboardingBar()

            ScheduleSectionCard { item in
                detailItem = item
            }
            .sheet(item: $detailItem) { item in
                ScheduleDetailSheet(item: item)
            }
        }
        .onAppear {
            // 冷启动到达时兜底刷新（设置页开启后的首次到达）
            let store = ScheduleStore.shared
            if store.isEnabled, store.authorizationStatus == .fullAccess {
                store.refreshCalendars()
                Task { await store.reloadActiveWindow() }
            }
        }
    }
}

// MARK: - 首页今日日程摘要条（有日程时出现，点击进今日看板）

struct TodayScheduleBar: View {
    @StateObject private var store = ScheduleStore.shared
    var onTap: () -> Void

    private var timedItems: [ScheduleItem] {
        store.cachedSchedules(onDay: Date()).filter { !$0.isAllDay }
    }

    private var nextItem: ScheduleItem? {
        let now = Date()
        return timedItems.first { $0.endDate > now } ?? timedItems.last
    }

    private var isOngoing: Bool {
        nextItem.map { $0.startDate <= Date() } ?? false
    }

    private var barText: String {
        guard let next = nextItem else { return "" }
        return timedItems.count == 1 ? next.title : "今日 \(timedItems.count) 场 · \(next.title)"
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return nextItem.map { formatter.string(from: $0.startDate) } ?? ""
    }

    var body: some View {
        if store.isEnabled, store.authorizationStatus == .fullAccess,
           let next = nextItem, !timedItems.isEmpty {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isOngoing ? next.calendarColor : .holoPrimary)

                    Text(barText)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    Text(isOngoing ? "进行中" : timeText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isOngoing ? .holoSuccess : .holoTextSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 8)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 日程区块（今日场景容器）

struct ScheduleSectionCard: View {
    @StateObject private var store = ScheduleStore.shared
    /// 点击日程回调（弹详情），默认内部处理
    var onTapSchedule: ((ScheduleItem) -> Void)?

    private var todayItems: [ScheduleItem] {
        store.cachedSchedules(onDay: Date())
    }

    var body: some View {
        // 无权限/未开启/今日无日程：整块不出现
        if store.isEnabled, store.authorizationStatus == .fullAccess, !todayItems.isEmpty {
            let timedItems = todayItems.filter { !$0.isAllDay }
            let allDayItems = todayItems.filter { $0.isAllDay }
            let completedCount = timedItems.filter { store.isCompleted($0) }.count

            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                    Text("今日日程")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)
                    if completedCount > 0 {
                        Text("\(completedCount)/\(timedItems.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.md)

                VStack(spacing: 0) {
                    // 全天日程：折叠为轻提示条，不占时间流
                    ForEach(allDayItems) { item in
                        allDayBanner(item)
                    }

                    // 定时日程：按开始时间排列
                    ForEach(Array(timedItems.enumerated()), id: \.element.id) { index, item in
                        ScheduleRowCard(item: item) {
                            onTapSchedule?(item)
                        }
                        if index < timedItems.count - 1 {
                            Divider().padding(.leading, HoloSpacing.md)
                        }
                    }
                }
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            }
        }
    }

    /// 全天日程折叠条（如假期/生日）
    private func allDayBanner(_ item: ScheduleItem) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            Circle()
                .fill(item.calendarColor)
                .frame(width: 8, height: 8)
            Text(item.title)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Text("全天")
                .font(.system(size: 10))
                .foregroundColor(.holoTextSecondary.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.holoTextSecondary.opacity(0.08)))
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 8)
    }
}

// MARK: - 单条日程行

struct ScheduleRowCard: View {
    @StateObject private var store = ScheduleStore.shared
    let item: ScheduleItem
    var onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            // 勾完成（仅 Holo 本地状态）
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.setCompleted(item, !store.isCompleted(item))
                }
            } label: {
                Image(systemName: store.isCompleted(item) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(store.isCompleted(item) ? .holoSuccess : .holoTextSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)

            // 日历色条
            RoundedRectangle(cornerRadius: 2)
                .fill(item.calendarColor)
                .frame(width: 4, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.holoBody)
                    .foregroundColor(store.isCompleted(item) ? .holoTextSecondary : .holoTextPrimary)
                    .strikethrough(store.isCompleted(item), color: .holoTextSecondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(timeRangeText)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    if let location = item.location, !location.isEmpty {
                        Text("· \(location)")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            Text(item.calendarTitle)
                .font(.system(size: 10))
                .foregroundColor(.holoTextSecondary.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    private var timeRangeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if item.isAllDay { return "全天" }
        return "\(formatter.string(from: item.startDate)) – \(formatter.string(from: item.endDate))"
    }
}

// MARK: - 日程详情弹窗

struct ScheduleDetailSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var store = ScheduleStore.shared
    let item: ScheduleItem
    /// EventKitUI 原始日程呈现
    @State private var showsOriginalEvent = false
    /// 日程转任务（跟进任务）
    @State private var showsFollowUpTask = false

    var body: some View {
        NavigationStack {
            VStack(spacing: HoloSpacing.lg) {
                VStack(spacing: 0) {
                    detailRow(icon: "calendar", title: item.calendarTitle, value: "") {
                        HStack {
                            Circle().fill(item.calendarColor).frame(width: 10, height: 10)
                            Text(item.calendarTitle).font(.holoBody).foregroundColor(.holoTextPrimary)
                            Spacer()
                        }
                    }

                    Divider().padding(.horizontal, HoloSpacing.md)

                    detailRow(icon: "clock", title: timeText, value: "") {
                        HStack {
                            Text(timeText).font(.holoBody).foregroundColor(.holoTextPrimary)
                            Spacer()
                        }
                    }

                    if let location = item.location, !location.isEmpty {
                        Divider().padding(.horizontal, HoloSpacing.md)
                        detailRow(icon: "mappin.and.ellipse", title: location, value: "") {
                            HStack {
                                Text(location).font(.holoBody).foregroundColor(.holoTextPrimary)
                                Spacer()
                            }
                        }
                    }

                    Divider().padding(.horizontal, HoloSpacing.md)

                    Button {
                        withAnimation { store.setCompleted(item, !store.isCompleted(item)) }
                    } label: {
                        HStack {
                            Image(systemName: store.isCompleted(item) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(store.isCompleted(item) ? .holoSuccess : .holoTextSecondary)
                            Text(store.isCompleted(item) ? "已标记完成（点按取消）" : "标记完成")
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, HoloSpacing.md)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))

                // 转跟进任务：预填标题/来源描述/时间段（非全天）
                Button {
                    showsFollowUpTask = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("添加跟进任务")
                            .font(.holoBody)
                    }
                    .foregroundColor(.holoPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoPrimary.opacity(0.1)))
                }
                .buttonStyle(.plain)

                // 只读说明 + 去系统日历
                Button {
                    showsOriginalEvent = true
                } label: {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                        Text("在系统日历中查看 / 编辑")
                            .font(.holoBody)
                    }
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoTextSecondary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.md)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .sheet(isPresented: $showsOriginalEvent) {
                OriginalEventSheet(item: item)
            }
            .sheet(isPresented: $showsFollowUpTask) {
                TaskDetailView(
                    repository: TodoRepository.shared,
                    list: nil,
                    defaultDueDate: item.startDate,
                    prefilledTitle: "跟进：\(item.title)",
                    prefilledDescription: "来源日程：\(followUpSourceText)",
                    prefilledPlannedRange: item.isAllDay ? nil : (start: item.startDate, end: item.endDate)
                )
            }
        }
        .presentationDetents([.medium])
    }

    private var followUpSourceText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        if item.isAllDay {
            return "\(item.title)（\(item.calendarTitle) · 全天）"
        }
        return "\(formatter.string(from: item.startDate)) \(item.title)（\(item.calendarTitle)）"
    }

    private func detailRow(icon: String, title: String, value: String, content: () -> some View) -> some View {
        HStack(spacing: HoloSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(.holoPrimary)
                .frame(width: 24)
            content()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 12)
    }

    private var timeText: String {
        let formatter = DateFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "zh_CN")
        dayFormatter.dateFormat = "M月d日 EEE"
        formatter.dateFormat = "HH:mm"
        if item.isAllDay {
            return "\(dayFormatter.string(from: item.startDate)) · 全天"
        }
        return "\(dayFormatter.string(from: item.startDate)) \(formatter.string(from: item.startDate)) – \(formatter.string(from: item.endDate))"
    }
}

/// 用 EventKitUI 呈现系统原始日程（只读查看，编辑去系统日历）
private struct OriginalEventSheet: UIViewControllerRepresentable {
    let item: ScheduleItem

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = EKEventViewController()
        if let store = ScheduleStore.sharedEventStore,
           let event = store.event(withIdentifier: item.eventIdentifier) {
            vc.event = event
        }
        vc.allowsEditing = false
        vc.allowsCalendarPreview = true
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
