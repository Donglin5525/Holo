//
//  MemoryGalleryTimelineView.swift
//  Holo
//
//  记忆长廊默认页（长廊减法设计 · 暖光规格 §2「长廊默认页」，原型即契约）：
//  - 月份分组（最近在上），章节标题吸顶；日期列 46pt + 14pt 间隔 + 细线小点
//  - 每天露一条主预览：带附件想法 > 可读正文想法 > 最近一条有时刻记录
//  - 两条及以上显示「当天 N 条记录」，点一下原地展开其余记录（同一时间只展开一天）
//  - 找日期/回到最近/在长廊看这天统一经 findDate.pendingJump 定位；空白日临时落位
//  - 同步中/部分失败/全空/加载态沿用原型状态文案
//

import SwiftUI

// MARK: - 主预览选取（纯函数，单测入口）

enum MemoryGalleryDayPreview {

    /// 把当天事件拆成「主预览 + 其余」。
    /// 主预览优先级：带附件的想法 > 有可读正文的想法 > 最近一条有可靠时刻的记录 > 稳定身份兜底。
    /// 其余：可靠时刻从晚到早，无可靠时刻置末。
    static func split(_ events: [CalendarEvent]) -> (featured: CalendarEvent?, others: [CalendarEvent]) {
        guard !events.isEmpty else { return (nil, []) }
        let featured = pickFeatured(events)
        let rest = events.filter { $0.id != featured.id }
        let timed = rest.filter(\.hasReliableTime).sorted { lhs, rhs in
            lhs.date != rhs.date ? lhs.date > rhs.date : lhs.id.uuidString < rhs.id.uuidString
        }
        let untimed = rest.filter { !$0.hasReliableTime }.sorted { $0.id.uuidString < $1.id.uuidString }
        return (featured, timed + untimed)
    }

    private static func pickFeatured(_ events: [CalendarEvent]) -> CalendarEvent {
        func latest(_ pool: [CalendarEvent]) -> CalendarEvent? {
            pool.max { lhs, rhs in
                lhs.date != rhs.date ? lhs.date < rhs.date : lhs.id.uuidString > rhs.id.uuidString
            }
        }
        let thoughts = events.filter { $0.module == .thought }
        if let withImage = latest(thoughts.filter { !$0.attachmentThumbnails.isEmpty }) {
            return withImage
        }
        if let readable = latest(thoughts.filter { hasReadableText($0) }) {
            return readable
        }
        if let timed = latest(events.filter(\.hasReliableTime)) {
            return timed
        }
        return events.min { $0.id.uuidString < $1.id.uuidString } ?? events[0]
    }

    static func hasReadableText(_ event: CalendarEvent) -> Bool {
        let text = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text != String(localized: "未命名想法")
    }
}

// MARK: - 长廊时间线页

struct MemoryGalleryTimelineView: View {
    let eventsByDay: [Date: [CalendarEvent]]
    /// 数据修订号：窗口续载完成后变化，用来判断「已到最早的记录」。
    let dataRevision: UUID
    let isInitialLoading: Bool
    /// 加载失败的模块（部分失败时顶部提示并保留成功项）。
    let failedModules: [CalendarModule]
    @ObservedObject var findDate: MemoryGalleryFindDateModel
    let onSelect: (CalendarEvent) -> Void
    let onEnsureData: (Date) -> Void
    let onRetry: () -> Void

    @State private var expandedDay: Date?
    /// 从日期面板/漫步定位来的目标日（原型 is-target 高亮；空白日临时落位）。
    @State private var selectedDay: Date?
    @State private var isFirstRowVisible = true
    @State private var extendRequestedFor: Date?
    @State private var reachedEarliest = false
    /// 视口内可见的日期行（LazyVStack 懒加载边界近似）；最新一枚=当前阅读日。
    @State private var visibleDays: Set<Date> = []
    /// 远跳后「回到最近」等今天窗口重载完成再定位。
    @State private var awaitingBackToRecent = false

    // 字号随 Dynamic Type 缩放（§2：字号随 Dynamic Type 缩放；交互审查 P1）。
    @ScaledMetric(relativeTo: .largeTitle) private var monthTitleSize: CGFloat = 32
    @ScaledMetric(relativeTo: .title) private var dayNumberSize: CGFloat = 30
    @ScaledMetric(relativeTo: .title3) private var leadHeadlineSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var rowTitleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var rowValueSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var metaSize: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var minorSize: CGFloat = 13
    @ScaledMetric(relativeTo: .title2) private var stateTitleSize: CGFloat = 26

    private let calendar = Calendar.current

    // MARK: 派生数据

    private var recordDays: [Date] {
        eventsByDay.filter { !$0.value.isEmpty }.keys.sorted(by: >)
    }

    private var mostRecentDay: Date? { recordDays.first }

    /// 展示的日序列：有记录的日 +（空白的目标日临时插入），新到旧。
    private var displayDays: [Date] {
        var days = recordDays
        if let selectedDay, !days.contains(selectedDay) {
            days.append(selectedDay)
            days.sort(by: >)
        }
        return days
    }

    private struct Chapter: Identifiable {
        let month: Date
        let days: [Date]
        var id: Date { month }
    }

    private var chapters: [Chapter] {
        var grouped: [Date: [Date]] = [:]
        for day in displayDays {
            let comps = calendar.dateComponents([.year, .month], from: day)
            let month = calendar.date(from: comps) ?? day
            grouped[month, default: []].append(day)
        }
        return grouped.keys.sorted(by: >).map { Chapter(month: $0, days: grouped[$0] ?? []) }
    }

    private var showBackToRecent: Bool {
        guard let mostRecentDay else { return false }
        return !isFirstRowVisible || (selectedDay != nil && selectedDay != mostRecentDay)
    }

    // MARK: Body

    var body: some View {
        Group {
            if isInitialLoading && eventsByDay.isEmpty {
                stateView(icon: "book", title: "正在打开长廊", message: "正在读取你的记录。", action: nil)
            } else if recordDays.isEmpty && selectedDay == nil {
                if failedModules.isEmpty {
                    stateView(icon: "book", title: "长廊还没有记录",
                              message: "写下的想法、账单、打卡和完成的任务，会按日期出现在这里。",
                              action: ("写条想法", { DeepLinkState.shared.navigate(to: .recordThought) }))
                } else {
                    stateView(icon: "info.circle", title: "暂时无法载入记录",
                              message: "可以稍后再试一次。", action: ("重试", onRetry))
                }
            } else {
                timeline
            }
        }
        .background(Color.holoToolBackground)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !failedModules.isEmpty { failureNotice }
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        Section {
                            ForEach(chapter.days, id: \.self) { day in
                                dayRow(day)
                                    .id(day)
                            }
                        } header: {
                            // 章节上距放在吸顶头的背景之内：否则吸顶时头部上方留透明缝，
                            // 滚动中会露出上一月的节尾行（冒烟判读实抓）。
                            monthHeader(chapter.month, topInset: index == 0 ? 24 : 34)
                        }
                    }
                    tailView
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 55)
            }
            .overlay(alignment: .bottomTrailing) {
                if showBackToRecent {
                    backToRecentButton { performBackToRecent(proxy: proxy) }
                }
            }
            .onChange(of: findDate.pendingJump) { _, request in
                guard let request else { return }
                jump(to: request.day, proxy: proxy)
                findDate.pendingJump = nil
            }
            .onChange(of: dataRevision) { _, _ in
                // 续载完成后最早日没变 → 已到最早的记录。
                if let requested = extendRequestedFor, requested == recordDays.last {
                    reachedEarliest = true
                }
                // 远跳后的回到最近：今天窗口重载完成，定位到最新记录日。
                if awaitingBackToRecent {
                    awaitingBackToRecent = false
                    if let latest = mostRecentDay {
                        jump(to: latest, proxy: proxy)
                    }
                }
            }
            .onChange(of: findDate.backToRecentToken) { _, token in
                guard token != nil else { return }
                findDate.backToRecentToken = nil
                performBackToRecent(proxy: proxy)
            }
            .onAppear {
                if let request = findDate.pendingJump {
                    jump(to: request.day, proxy: proxy)
                    findDate.pendingJump = nil
                }
            }
        }
    }

    // MARK: 定位

    /// 视口最新可见日 → 找日期面板的初始月份/旧档位的落点（§2：月份跟随当前阅读章节）。
    private func syncReadingChapter() {
        guard let readingDay = visibleDays.max() else { return }
        let comps = calendar.dateComponents([.year, .month], from: readingDay)
        if let month = calendar.date(from: comps), findDate.readingDay != readingDay {
            findDate.readingMonth = month
            findDate.readingDay = readingDay
        }
    }

    /// 回到最近：近段已在窗口内直接定位；远跳后先回今天补窗口，数据回来再定位。
    private func performBackToRecent(proxy: ScrollViewProxy) {
        let today = calendar.startOfDay(for: Date())
        if let latest = mostRecentDay,
           let gap = calendar.dateComponents([.day], from: latest, to: today).day,
           gap <= 62 {
            jump(to: latest, proxy: proxy)
        } else {
            awaitingBackToRecent = true
            onEnsureData(today)
        }
    }

    private func jump(to day: Date?, proxy: ScrollViewProxy) {
        guard let day else { return }
        let target = calendar.startOfDay(for: day)
        selectedDay = target
        // 有多条时自动展开（§2：点日期直接回到该天，有多条时自动展开）。
        expandedDay = (eventsByDay[target]?.count ?? 0) > 1 ? target : nil
        onEnsureData(target)
        DispatchQueue.main.async {
            withAnimation(HoloAnimation.standard) {
                // 落点让出吸顶月头的高度：贴顶定位会让该日首行被月头遮去上半（冒烟判读实抓）。
                proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.14))
            }
        }
    }

    /// 空白日的「去最近有记录的一天」：距离相同取较早日期。
    private func nearestRecordDay(to day: Date) -> Date? {
        recordDays.min { lhs, rhs in
            let dl = abs(lhs.timeIntervalSince(day))
            let dr = abs(rhs.timeIntervalSince(day))
            return dl != dr ? dl < dr : lhs < rhs
        }
    }

    // MARK: 月份章节头（吸顶）

    private func monthHeader(_ month: Date, topInset: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(month.formatted(.dateTime.month(.wide)))
                .font(.system(size: monthTitleSize, weight: .bold, design: .serif))
                .tracking(-1.9)
                .foregroundStyle(Color.holoToolText)
            Text(String(calendar.component(.year, from: month)))
                .font(.system(size: monthTitleSize * 0.5625, design: .serif))
                .foregroundStyle(Color.holoToolTextSecondary)
            Spacer(minLength: 0)
        }
        .padding(.top, topInset + 6)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.holoToolBorder).frame(height: 1)
        }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: 日行

    private func dayRow(_ day: Date) -> some View {
        let events = eventsByDay[day] ?? []
        let split = MemoryGalleryDayPreview.split(events)
        let isToday = calendar.isDateInToday(day)
        let isTarget = selectedDay == day
        return HStack(alignment: .top, spacing: 14) {
            dayMarker(day, highlighted: isToday || isTarget, isToday: isToday)
            dayContent(day: day, events: events, featured: split.featured, others: split.others)
        }
        .onAppear {
            visibleDays.insert(day)
            syncReadingChapter()
            if day == mostRecentDay {
                isFirstRowVisible = true
                // 远跳后窗口被替换：从最新边缘向今天方向续载回近段历史。
                onEnsureData(day)
            }
            if day == recordDays.last {
                // 滚到已载入的最早一天：向更早续载。
                extendRequestedFor = day
                onEnsureData(day)
            }
        }
        .onDisappear {
            visibleDays.remove(day)
            syncReadingChapter()
            if day == mostRecentDay { isFirstRowVisible = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(dayAccessibilityLabel(day, isToday: isToday))
    }

    private func dayAccessibilityLabel(_ day: Date, isToday: Bool) -> String {
        let base = day.formatted(.dateTime.month().day().weekday(.wide))
        return isToday ? base + "，" + String(localized: "今天") : base
    }

    private func dayMarker(_ day: Date, highlighted: Bool, isToday: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: dayNumberSize, design: .serif))
                .tracking(-1.95)
                .foregroundStyle(highlighted ? Color.holoPrimary : Color.holoToolText)
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: metaSize))
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.top, 5)
            if isToday {
                Text("今天")
                    .font(.system(size: metaSize))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        }
        .padding(.top, 22)
        .frame(width: 46, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.holoToolBorder).frame(width: 1)
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(highlighted ? Color.holoPrimary : Color.holoToolTextSecondary)
                .frame(width: 5, height: 5)
                .background {
                    if highlighted {
                        Circle().fill(Color.holoPrimary.opacity(0.18)).frame(width: 11, height: 11)
                    }
                }
                .offset(x: 2, y: 35)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dayContent(day: Date, events: [CalendarEvent],
                            featured: CalendarEvent?, others: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let featured {
                if featured.module == .thought {
                    leadRecord(featured)
                } else {
                    recordRow(featured)
                }
            } else {
                chosenEmpty(day)
            }
            if !others.isEmpty {
                let isExpanded = expandedDay == day
                Button {
                    withAnimation(HoloAnimation.standard) {
                        expandedDay = isExpanded ? nil : day
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(isExpanded ? "收起当天" : "当天 \(events.count) 条记录")
                            .font(.system(size: minorSize))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .foregroundStyle(Color.holoPrimary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(others) { event in
                            recordRow(event)
                                .overlay(alignment: .top) {
                                    Rectangle().fill(Color.holoToolBorder).frame(height: 1)
                                }
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.holoToolBorder).frame(height: 1)
        }
    }

    // MARK: 记录行

    /// 主预览想法：可选 1.88:1 大图 + 衬线标题 + 模块元信息。
    private func leadRecord(_ event: CalendarEvent) -> some View {
        Button {
            onSelect(event)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let thumb = event.attachmentThumbnails.first {
                    MemoryGalleryThumbnail(data: thumb)
                        .aspectRatio(1.88, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .padding(.bottom, 11)
                }
                Text(event.title)
                    .font(.system(size: leadHeadlineSize, weight: .bold, design: .serif))
                    .lineSpacing(5)
                    .foregroundStyle(Color.holoPrimary)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Image(systemName: event.module.iconName)
                        .font(.system(size: 11))
                    Text(metaText(event))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: metaSize))
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 紧凑记录行：30pt 图标块 + 标题/元信息 + 金额或状态（缺省箭头），最小 54pt。
    private func recordRow(_ event: CalendarEvent) -> some View {
        Button {
            onSelect(event)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: event.module.iconName)
                    .font(.system(size: minorSize))
                    .foregroundStyle(Color.holoPrimary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.holoToolInset))
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: rowTitleSize, weight: .medium))
                        .foregroundStyle(Color.holoToolText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(metaText(event))
                        .font(.system(size: metaSize))
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
                Spacer(minLength: 0)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: rowValueSize).monospacedDigit())
                        .foregroundStyle(Color.holoToolText)
                        .lineLimit(1)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
            }
            .padding(.vertical, 5)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func metaText(_ event: CalendarEvent) -> String {
        let time = event.hasReliableTime
            ? event.date.formatted(.dateTime.hour().minute())
            : String(localized: "当天")
        return event.module.displayName + " · " + time
    }

    /// 主动查到的空白日：临时落位并提供「去最近有记录的一天」。
    private func chosenEmpty(_ day: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(failedModules.isEmpty ? "这一天没有记录" : "这一天暂无已载入的记录")
                .font(.system(size: rowTitleSize))
                .foregroundStyle(Color.holoToolTextSecondary)
            if let nearest = nearestRecordDay(to: day) {
                Button("去最近有记录的一天") {
                    findDate.requestJump(to: nearest)
                }
                .font(.system(size: minorSize))
                .foregroundStyle(Color.holoPrimary)
                .frame(minHeight: 44, alignment: .leading)
            }
        }
        .padding(.top, 8)
        .frame(minHeight: 88, alignment: .top)
    }

    // MARK: 状态与尾部

    private var failureNotice: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle")
                .font(.system(size: minorSize))
                .foregroundStyle(Color.holoPrimary)
            Text(failedModules.map(\.displayName).joined(separator: "、") + String(localized: "暂未载入"))
                .font(.system(size: minorSize))
                .foregroundStyle(Color.holoToolTextSecondary)
            Spacer(minLength: 0)
            Button("重试", action: onRetry)
                .font(.system(size: minorSize))
                .frame(minHeight: 44)
                .foregroundStyle(Color.holoPrimary)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.holoToolBorder).frame(height: 1)
        }
    }

    @ViewBuilder
    private var tailView: some View {
        if reachedEarliest && failedModules.isEmpty && recordDays.count > 1 {
            Text("已到最早的记录")
                .font(.system(size: minorSize))
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 25)
                .padding(.bottom, 4)
        }
    }

    private func backToRecentButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                Text("回到最近")
                    .font(.system(size: minorSize))
            }
            .foregroundStyle(Color.holoToolText)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Capsule().fill(Color.holoToolBackground))
            .overlay(Capsule().strokeBorder(Color.holoToolBorder, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.12), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .accessibilityIdentifier("memoryGallery.backToRecent")
    }

    private func stateView(icon: String, title: LocalizedStringKey, message: LocalizedStringKey,
                           action: (title: LocalizedStringKey, handler: () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(Color.holoPrimary)
                .padding(.bottom, 18)
            Text(title)
                .font(.system(size: stateTitleSize, weight: .bold, design: .serif))
                .foregroundStyle(Color.holoToolText)
            Text(message)
                .font(.system(size: rowTitleSize))
                .foregroundStyle(Color.holoToolTextSecondary)
                .lineSpacing(5)
                .padding(.top, 8)
            if let action {
                Button(action: action.handler) {
                    Text(action.title)
                        .font(.system(size: rowTitleSize))
                        .foregroundStyle(Color.holoPrimary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.holoToolInset))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.holoToolBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 17)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 缩略图（UIKit/AppKit 双端）

private struct MemoryGalleryThumbnail: View {
    let data: Data

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable()
        } else {
            Color.holoToolInset
        }
        #else
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable()
        } else {
            Color.holoToolInset
        }
        #endif
    }
}
