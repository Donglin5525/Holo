//
//  MemoryGalleryFindDateModel.swift
//  Holo
//
//  「找日期」面板的共享模型（暖光规格 §2「找日期与打开漫步」）：
//  - 长廊顶栏按钮与日历页共用的同一展示宿主：日期选择 / 随机漫步两个面板状态互斥
//  - 漫步会话挂在模型上：面板关合不丢本轮已看集合；长廊会话结束才清空
//

import Foundation
import SwiftUI
import Combine
import CoreData

@MainActor
final class MemoryGalleryFindDateModel: ObservableObject {
    enum Mode {
        case calendar
        case walk
    }

    @Published var isPresented = false
    @Published private(set) var mode: Mode = .calendar

    /// 长廊时间线的定位请求（找日期选日 / 回到最近 / 在长廊看这天）。
    /// 时间线页消费后清空；token 保证同一天重复点击也能再次触发滚动。
    struct GalleryJump: Equatable {
        let day: Date
        let token = UUID()
    }
    @Published var pendingJump: GalleryJump?

    /// 时间线当前阅读章节月（吸顶月头）；找日期面板初始月份跟随它（§2）。
    @Published var readingMonth: Date?
    /// 时间线当前阅读日（视口最新可见日）；旧档位从长廊切走时的落点。
    @Published var readingDay: Date?

    func requestJump(to day: Date) {
        pendingJump = GalleryJump(day: Calendar.current.startOfDay(for: day))
    }

    /// 回到最近（面板行/悬浮钮共用）：由时间线消费，统一处理远跳后的窗口回补。
    @Published var backToRecentToken: UUID?

    func requestBackToRecent() {
        backToRecentToken = UUID()
    }

    /// 弹层整体消失（含下拉手势）：结束当前取数/动效（§2「关闭或下拉收起」）。
    func handleSheetDismissed() {
        walkSession.close()
        mode = .calendar
    }

    let walkSession = MemoryRandomWalkSession()

    /// 顶栏「找日期」：保留长廊当前位置，面板跟随当前阅读章节月份。
    func open() {
        mode = .calendar
        isPresented = true
    }

    /// 面板内切到随机漫步：就地把面板从日期选择器切到漫步，不叠第二层 sheet。
    func switchToWalk() {
        mode = .walk
        if walkSession.phase == .idle {
            walkSession.start()
        }
    }

    /// 回到日期选择（漫步关闭时若仍在面板内）。
    func switchToCalendar() {
        mode = .calendar
    }

    func dismiss() {
        walkSession.close()
        isPresented = false
        mode = .calendar
    }

    /// 长廊会话结束（页面消失）：清本轮集合。
    func endGallerySession() {
        isPresented = false
        mode = .calendar
        walkSession.resetSession()
    }
}

/// 「找日期」面板：年月切换、周一至周日、有记录标记、回到最近、随机漫步行。
struct MemoryGalleryFindDateSheet: View {
    @ObservedObject var model: MemoryGalleryFindDateModel
    let calendar: Calendar
    /// 当前聚焦日（选择器高亮）。
    let focusedDate: Date
    /// 某日记录数（已载入窗口内；nil = 无记录或未载入）。
    let recordCount: (Date) -> Int?
    /// 面板跨月时让宿主补拉该月数据。
    let ensureData: (Date) -> Void
    /// 点某天：回到长廊该天并收起面板。
    let onSelectDay: (Date) -> Void
    /// 回到最近有记录的日子（今天无记录时往前找）。
    let onBackToLatest: () -> Void
    /// 漫步里点开一条原记录（详情弹层/想法深链由宿主决定）。
    let onOpenEvent: (CalendarEvent) -> Void

    @State private var monthAnchor: Date?
    @State private var showYearMenu = false
    /// 漫步里点开的非想法记录：在面板内部嵌套弹层呈现，漫步状态原地保留
    /// （同一视图链并发两个 sheet 会被丢弃/顶掉——交互审查 P0）。
    @State private var walkDetailEvent: CalendarEvent?
    /// 漫步里点开的想法：面板内全文阅读，不跳出长廊、不清本轮已看集合（交互审查 P0）。
    @State private var walkThoughtEvent: CalendarEvent?
    // 原型即契约：固定字号（px→pt 1:1），不随系统 Dynamic Type 缩放。
    private let weekdaySize: CGFloat = 12
    private let dayNumberSize: CGFloat = 14
    private let footSize: CGFloat = 13
    private let launchTitleSize: CGFloat = 15

    private var displayedMonth: Date {
        monthAnchor ?? model.readingMonth ?? focusedDate
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.mode == .walk {
                MemoryRandomWalkView(
                    session: model.walkSession,
                    calendar: calendar,
                    onClose: { model.dismiss() },
                    onOpenInGallery: { day in
                        onSelectDay(day)
                    },
                    onOpenEvent: { event in
                        if event.module == .thought {
                            walkThoughtEvent = event
                        } else {
                            walkDetailEvent = event
                        }
                    }
                )
            } else {
                calendarPanel
            }
        }
        // 固定高度档：6 行月历+两行动作需 ~540pt，中等档会把顶部月份标题顶出可视区（冒烟实抓）；
        // 日期面板与漫步共用同一档，切换时弹层高度不跳（§2：就地切换、期间固定高度）。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(620), .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color.gallerySurface)
        .sheet(item: $walkDetailEvent) { event in
            CalendarEventDetailSheet(event: event, onShowInTimeline: nil)
        }
        .sheet(item: $walkThoughtEvent) { event in
            MemoryWalkThoughtReader(event: event) {
                // 显式「在想法中打开」：用户主动离开漫步，整面板收起后再深链。
                walkThoughtEvent = nil
                model.dismiss()
                onOpenEvent(event)
            }
        }
        .onAppear {
            if monthAnchor == nil { monthAnchor = model.readingMonth ?? focusedDate }
        }
    }

    // MARK: - 日期选择面板

    private var calendarPanel: some View {
        VStack(spacing: 12) {
            panelHeader
            monthHeader
            weekdayHeader
            dayGrid
            Divider().padding(.horizontal, 20)
            backToLatestRow
            randomWalkRow
        }
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// 原型 dialog-head 1:1：衬线标题 + 右侧「关闭」+ 底部细线（padding 13/0/9）。
    private var panelHeader: some View {
        HStack {
            Text("找日期")
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(Color.galleryInk)
            Spacer()
            Button {
                model.dismiss()
            } label: {
                Text("关闭")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.galleryAccent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("memoryGallery.findDate.close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 13)
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.galleryRule).frame(height: 1)
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("memoryGallery.findDate.prevMonth")
            Spacer()
            Button {
                showYearMenu.toggle()
            } label: {
                Text(monthTitle)
                    .font(.headline)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memoryGallery.findDate.title")
            .popover(isPresented: $showYearMenu) {
                yearMenu
            }
            Spacer()
            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("memoryGallery.findDate.nextMonth")
        }
        .padding(.horizontal, 12)
    }

    private var monthTitle: String {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        return String(format: "%d 年 %d 月", comps.year ?? 0, comps.month ?? 0)
    }

    private var yearMenu: some View {
        VStack(spacing: 4) {
            ForEach(availableYears, id: \.self) { year in
                Button("\(String(year)) 年") {
                    if let anchor = calendar.date(bySetting: .year, value: year, of: displayedMonth) {
                        monthAnchor = calendar.startOfDay(for: anchor)
                        ensureData(monthAnchor ?? displayedMonth)
                    }
                    showYearMenu = false
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .frame(minWidth: 120)
        .presentationCompactAdaptation(.popover)
    }

    private var availableYears: [Int] {
        let thisYear = calendar.component(.year, from: Date())
        return stride(from: thisYear, through: thisYear - 6, by: -1).map { $0 }
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            monthAnchor = next
            ensureData(next)
        }
    }

    private var weekdayHeader: some View {
        // 周一首（与 CalendarRangeBuilder 同约定）；原型 weekdays：quiet 12pt、上下 6pt
        let symbols = calendar.veryShortWeekdaySymbols
        let mondayFirst = (0..<7).map { symbols[($0 + 1) % 7] }
        return HStack {
            ForEach(mondayFirst, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: weekdaySize))
                    .foregroundStyle(Color.galleryQuiet)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var dayGrid: some View {
        let days = monthDays
        let startOfWeekdayIndex = { () -> Int in
            let weekday = calendar.component(.weekday, from: days.first ?? displayedMonth)
            return (weekday - 1 + 6) % 7
        }()
        let today = calendar.startOfDay(for: Date())
        let focused = calendar.startOfDay(for: focusedDate)

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
            ForEach(0..<startOfWeekdayIndex, id: \.self) { _ in
                Color.clear.frame(height: 44)
            }
            ForEach(days, id: \.self) { day in
                let startOfDay = calendar.startOfDay(for: day)
                let isFuture = startOfDay > today
                let count = recordCount(startOfDay)
                Button {
                    onSelectDay(startOfDay)
                } label: {
                    VStack(spacing: 3) {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: dayNumberSize).monospacedDigit())
                            .foregroundStyle(isFuture ? Color.galleryInk.opacity(0.35)
                                         : (startOfDay == today ? Color.white : Color.galleryInk))
                        Circle()
                            .fill(isFuture ? Color.clear
                                  : (startOfDay == today ? Color.clear
                                     : (count != nil ? Color.galleryOrange : Color.clear)))
                            .frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .background {
                        if startOfDay == focused {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.galleryTint)
                                .frame(height: 44)
                        } else if startOfDay == today {
                            // 原型：今天=橙色实底+固定白字（深色下 GallerySurface 是暖深色，判读实抓改 .white）
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.galleryOrange)
                                .frame(height: 44)
                        }
                    }
                    .opacity(isFuture ? 0.35 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isFuture)
                .accessibilityLabel(dayAccessibilityLabel(startOfDay, isToday: startOfDay == today, hasRecords: count != nil))
            }
        }
        .padding(.horizontal, 20)
    }

    private func dayAccessibilityLabel(_ day: Date, isToday: Bool, hasRecords: Bool) -> String {
        var label = day.formatted(.dateTime.month().day())
        if hasRecords { label += "，" + String(localized: "有记录") }
        if isToday { label += "，" + String(localized: "今天") }
        return label
    }

    private var monthDays: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [] }
        var days: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// 原型 calendar-foot：左「● 有记录」图例（quiet 12pt）+ 右「回到最近」accent 文字钮。
    private var backToLatestRow: some View {
        HStack {
            HStack(spacing: 7) {
                Circle().fill(Color.galleryOrange).frame(width: 5, height: 5)
                Text("有记录")
                    .font(.system(size: weekdaySize))
                    .foregroundStyle(Color.galleryQuiet)
            }
            Spacer()
            Button {
                onBackToLatest()
            } label: {
                Text("回到最近")
                    .font(.system(size: footSize))
                    .foregroundStyle(Color.galleryAccent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memoryGallery.findDate.backToLatest")
        }
        .padding(.horizontal, 20)
    }

    /// 随机漫步行（原型 walk-launch：36pt inset 图标块 + 标题/副文案 + 右箭头，≥62pt 行高）。
    private var randomWalkRow: some View {
        Button {
            model.switchToWalk()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.galleryAccent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.galleryInset))
                VStack(alignment: .leading, spacing: 2) {
                    Text("随机漫步")
                        .font(.system(size: launchTitleSize, weight: .semibold))
                        .foregroundStyle(Color.galleryInk)
                    Text("去一个有记录的旧日")
                        .font(.system(size: weekdaySize))
                        .foregroundStyle(Color.galleryQuiet)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.galleryQuiet)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memoryGallery.randomWalk")
    }
}

// MARK: - 漫步内想法全文阅读（面板内呈现，不跳出长廊）

/// 漫步里点开想法：读可见全文（方案 §6——想法详情必须显示完整可见原文，
/// 不能用只含标题的弹层冒充；也不跳出长廊清本轮状态）。
/// 失效与故障分态：记录不存在/已删/归档 → 「这条记录暂时无法查看」；读取出错 → 「暂时无法载入」+ 重试。
struct MemoryWalkThoughtReader: View {
    let event: CalendarEvent
    /// 显式「在想法中打开」：由宿主收面板后深链跳转。
    let onOpenInThoughts: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case loaded(text: String, date: Date)
        case unavailable
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("想法原文")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("关闭")
                        .font(.subheadline)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 7)
            .padding(.bottom, 9)

            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let text, let date):
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 附件与文字同页呈现（设计稿：图片和文字指向同一条原记录；对抗审查必改4）
                        ForEach(Array(event.attachmentThumbnails.enumerated()), id: \.offset) { _, thumb in
                            MemoryGalleryThumbnail(data: thumb)
                                .aspectRatio(1.88, contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        Text(date.formatted(.dateTime.year().month().day().weekday(.wide).hour().minute()))
                            .font(.footnote)
                            .foregroundStyle(Color.galleryQuiet)
                        Text(text)
                            .font(.body)
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                Button(action: onOpenInThoughts) {
                    Text("在想法中打开")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            case .unavailable:
                message("这条记录暂时无法查看", retry: false)
            case .failed:
                message("暂时无法载入", retry: true)
            }
        }
        .background(Color.galleryPaper)
        .presentationDetents([.large])
        .task { load() }
    }

    private func message(_ text: LocalizedStringKey, retry: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(Color.galleryQuiet)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.galleryQuiet)
            if retry {
                Button("重试") { load() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 按可见性回查：区分「确实失效」与「读取故障」（方案 §6）。
    private func load() {
        state = .loading
        let context = CoreDataStack.shared.viewContext
        do {
            guard let thought = try context.existingObject(with: event.originID) as? Thought else {
                state = .unavailable
                return
            }
            if thought.deletedAt != nil || thought.isArchived {
                state = .unavailable
                return
            }
            let text = thought.content.trimmingCharacters(in: .whitespacesAndNewlines)
            state = .loaded(text: text.isEmpty ? event.title : text, date: thought.createdAt)
        } catch {
            state = .failed
        }
    }
}


/// 附件缩略图（阅读页本地版；UIKit/AppKit 双端）。
private struct MemoryGalleryThumbnail: View {
    let data: Data

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable()
        } else {
            Color.galleryInset
        }
        #else
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable()
        } else {
            Color.galleryInset
        }
        #endif
    }
}
