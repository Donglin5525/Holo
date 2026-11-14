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
    /// 回到最近·远跳分支：强制刷新今天窗口（ensureTimelineData 的边距守卫会让已覆盖今天的窗口无动作，
    /// revision 不变→awaitingBackToRecent 永不消费=死按钮；对抗审查 G 必改1）。
    let onBackToLatestReload: () -> Void

    @State private var expandedDay: Date?
    /// 从日期面板/漫步定位来的目标日（原型 is-target 高亮；空白日临时落位）。
    @State private var selectedDay: Date?
    @State private var isFirstRowVisible = true
    @State private var extendRequestedFor: Date?
    @State private var reachedEarliest = false
    /// 远跳后「回到最近」等今天窗口重载完成再定位。
    @State private var awaitingBackToRecent = false

    // 原型即契约：字号为原型 px→pt 固定值，不随系统 Dynamic Type 缩放
    //（2026-11-14 东林真机实报「字体跟原型对不上」定谳：@ScaledMetric 在非默认字号设备上全偏）。
    private let monthTitleSize: CGFloat = 32
    private let dayNumberSize: CGFloat = 30
    private let leadHeadlineSize: CGFloat = 20
    private let rowTitleSize: CGFloat = 15
    private let rowValueSize: CGFloat = 14
    private let metaSize: CGFloat = 12
    private let minorSize: CGFloat = 13
    private let stateTitleSize: CGFloat = 26

    private let calendar = Calendar.current

    // MARK: 派生数据

    /// 分组结果缓存（在档坑「分组计算属性=body 每帧全量重算」；只在数据修订/目标日变化时重建）。
    @State private var recordDaysCache: [Date] = []
    @State private var displayDaysCache: [Date] = []
    @State private var chaptersCache: [Chapter] = []

    private var recordDays: [Date] { recordDaysCache }
    private var mostRecentDay: Date? { recordDaysCache.first }
    private var displayDays: [Date] { displayDaysCache }

    /// 数据修订/目标日变化时重建分组（滚动帧内零重算）。
    private func rebuildSections() {
        var days = eventsByDay.filter { !$0.value.isEmpty }.keys.sorted(by: >)
        if let selectedDay, !days.contains(selectedDay) {
            days.append(selectedDay)
            days.sort(by: >)
        }
        var grouped: [Date: [Date]] = [:]
        for day in days {
            let comps = calendar.dateComponents([.year, .month], from: day)
            grouped[calendar.date(from: comps) ?? day, default: []].append(day)
        }
        displayDaysCache = days
        recordDaysCache = days.filter { !(selectedDay == $0 && (eventsByDay[$0]?.isEmpty ?? true)) }
        chaptersCache = grouped.keys.sorted(by: >).map { Chapter(month: $0, days: grouped[$0] ?? []) }
    }

    private struct Chapter: Identifiable {
        let month: Date
        let days: [Date]
        var id: Date { month }
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
        .background(Color.galleryPaper)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !failedModules.isEmpty { failureNotice }
                    ForEach(Array(chaptersCache.enumerated()), id: \.element.id) { index, chapter in
                        Section {
                            ForEach(chapter.days, id: \.self) { day in
                                dayRow(day)
                                    .id(day)
                            }
                        } header: {
                            // 章节上距放在吸顶头的背景之内：否则吸顶时头部上方留透明缝，
                            // 滚动中会露出上一月的节尾行（冒烟判读实抓）。
                            monthHeader(chapter.month, topInset: index == 0 ? 24 : 34)
                                // 阅读章节只按月头进入回写（在档坑：按行 onAppear 写 @Published
                                // 打穿 MemoryGalleryView 全量重渲染=滚动卡顿主因之一）。
                                .onAppear { syncReadingChapter(chapter) }
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
                // 定位时数据未到导致「多条自动展开」静默失效：数据到达后补一次（建议7）。
                if let target = selectedDay, expandedDay == nil,
                   (eventsByDay[target]?.count ?? 0) > 1 {
                    expandedDay = target
                }
            }
            .onChange(of: findDate.backToRecentToken) { _, token in
                guard token != nil else { return }
                findDate.backToRecentToken = nil
                performBackToRecent(proxy: proxy)
            }
            .onAppear {
                rebuildSections()
                if let request = findDate.pendingJump {
                    jump(to: request.day, proxy: proxy)
                    findDate.pendingJump = nil
                }
            }
            .onChange(of: dataRevision) { _, _ in rebuildSections() }
            .onChange(of: selectedDay) { _, _ in rebuildSections() }
        }
    }

    // MARK: 定位

    /// 月头进入懒加载窗口时回写阅读章节（月份变化才写，@Published 低频触发）。
    private func syncReadingChapter(_ chapter: Chapter) {
        if findDate.readingMonth != chapter.month {
            findDate.readingMonth = chapter.month
        }
        if let first = chapter.days.first, findDate.readingDay != first {
            findDate.readingDay = first
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
            onBackToLatestReload()
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
                .foregroundStyle(Color.galleryInk)
            Text(String(calendar.component(.year, from: month)))
                .font(.custom("Georgia", size: monthTitleSize * 0.5625))
                .foregroundStyle(Color.galleryQuiet)
            Spacer(minLength: 0)
        }
        .padding(.top, topInset + 6)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.galleryPaper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.galleryRule).frame(height: 1)
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
            if day == mostRecentDay { isFirstRowVisible = true }
            if day == recordDays.last {
                // 滚到已载入的最早一天：向更早续载。
                extendRequestedFor = day
                onEnsureData(day)
            }
        }
        .onDisappear {
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
                .font(.custom("Georgia", size: dayNumberSize))
                .tracking(-1.95)
                .foregroundStyle(highlighted ? Color.galleryAccent : Color.galleryInk)
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: metaSize))
                .foregroundStyle(Color.galleryQuiet)
                .padding(.top, 5)
            if isToday {
                Text("今天")
                    .font(.system(size: metaSize))
                    .foregroundStyle(Color.galleryQuiet)
            }
        }
        .padding(.top, 22)
        .frame(width: 46, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.galleryRule).frame(width: 1)
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(highlighted ? Color.galleryOrange : Color.galleryQuiet)
                .frame(width: 5, height: 5)
                .background {
                    if highlighted {
                        Circle().fill(Color.galleryTint).frame(width: 11, height: 11)
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
                    .foregroundStyle(Color.galleryAccent)
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
                                    Rectangle().fill(Color.galleryRule).frame(height: 1)
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
            Rectangle().fill(Color.galleryRule).frame(height: 1)
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
                    .foregroundStyle(Color.galleryAccent)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Image(systemName: event.module.iconName)
                        .font(.system(size: 11))
                    Text(metaText(event))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: metaSize))
                .foregroundStyle(Color.galleryQuiet)
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
                    .foregroundStyle(Color.galleryAccent)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.galleryInset))
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: rowTitleSize, weight: .medium))
                        .foregroundStyle(Color.galleryInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(metaText(event))
                        .font(.system(size: metaSize))
                        .foregroundStyle(Color.galleryQuiet)
                }
                Spacer(minLength: 0)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: rowValueSize).monospacedDigit())
                        .foregroundStyle(Color.galleryInk)
                        .lineLimit(1)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.galleryQuiet)
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
                .foregroundStyle(Color.galleryQuiet)
            if let nearest = nearestRecordDay(to: day) {
                Button("去最近有记录的一天") {
                    findDate.requestJump(to: nearest)
                }
                .font(.system(size: minorSize))
                .foregroundStyle(Color.galleryAccent)
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
                .foregroundStyle(Color.galleryAccent)
            Text(failedModules.map(\.displayName).joined(separator: "、") + String(localized: "暂未载入"))
                .font(.system(size: minorSize))
                .foregroundStyle(Color.galleryQuiet)
            Spacer(minLength: 0)
            Button("重试", action: onRetry)
                .font(.system(size: minorSize))
                .frame(minHeight: 44)
                .foregroundStyle(Color.galleryAccent)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.galleryRule).frame(height: 1)
        }
    }

    @ViewBuilder
    private var tailView: some View {
        if reachedEarliest && failedModules.isEmpty && recordDays.count > 1 {
            Text("已到最早的记录")
                .font(.system(size: minorSize))
                .foregroundStyle(Color.galleryQuiet)
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
            .foregroundStyle(Color.galleryInk)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Capsule().fill(Color.galleryPaper))
            .overlay(Capsule().strokeBorder(Color.galleryRule, lineWidth: 1))
            .shadow(color: Color(.sRGB, red: 0.224, green: 0.133, blue: 0.055, opacity: 0.15), radius: 6.5, y: 3)
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
                .foregroundStyle(Color.galleryAccent)
                .padding(.bottom, 18)
            Text(title)
                .font(.system(size: stateTitleSize, weight: .bold, design: .serif))
                .foregroundStyle(Color.galleryInk)
            Text(message)
                .font(.system(size: rowTitleSize))
                .foregroundStyle(Color.galleryQuiet)
                .lineSpacing(5)
                .padding(.top, 8)
            if let action {
                Button(action: action.handler) {
                    Text(action.title)
                        .font(.system(size: rowTitleSize))
                        .foregroundStyle(Color.galleryAccent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.galleryInset))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.galleryRule, lineWidth: 1))
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

/// 解码缓存（在档坑：UIImage(data:) 在 body 里=每次求值重新解码，滚动卡顿主因之一；
/// 与 AttachmentImageLoader 同思路，这里键取内容 hash）。
enum MemoryGalleryThumbnailCache {
    static let cache = NSCache<NSString, UIImage>()

    static func image(for data: Data) -> UIImage? {
        let key = NSString(string: String(data.hashValue) + "-" + String(data.count))
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct MemoryGalleryThumbnail: View {
    let data: Data

    var body: some View {
        #if canImport(UIKit)
        if let image = MemoryGalleryThumbnailCache.image(for: data) {
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
