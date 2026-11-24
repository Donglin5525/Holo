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
//  - 2026-11-23 审美七项：P4 月份名/想法节选改思源宋体（holoEditorialSerif，真正的中文衬线）；
//    P5 空态改 HoloQuietEmptyState；P7 旧记忆泛黄（纸面按天渐变铺满屏宽、墨色走
//    memoryAgingInk 环境键，基建见 MemoryGalleryAging.swift）
//

import SwiftUI
import ImageIO

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

    // MARK: P7 旧记忆泛黄

    @Environment(\.colorScheme) private var colorScheme
    /// 泛黄开关（默认开）：关闭时墨色回原色、纸面不铺背景
    @AppStorage(HoloPaperSettings.agingKey) private var agingEnabled = true

    @State private var expandedDay: Date?
    /// 同日同习惯聚合行展开的行 id（原型 ②：轻点看逐条时刻）
    @State private var expandedAggregations: Set<UUID> = []
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
    /// 想法标题=老长廊规格 15pt semibold 衬线（2026-11-15 东林拍板：与旧版同规格，
    /// 覆盖原型 20pt 粗衬线——大号衬线在真机上「廉价」）。
    private let leadHeadlineSize: CGFloat = 15
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
    /// P7 泛黄颜色按天缓存（纯函数结果；与 chaptersCache 同步重建，滚动帧内零重算）。
    /// 键含每个展示日与其前一天（前一天是行纸面渐变的底色端点）。
    @State private var agingCache: [Date: MemoryAgedDay] = [:]

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
        rebuildAgingCache(for: days)
    }

    /// P7：按天重算泛黄颜色（daysAgo → 进度 → 端点插值，深浅色各一套）。
    /// 深浅色切换由 body 的 onChange(of: colorScheme) 触发整组重建。
    private func rebuildAgingCache(for days: [Date]) {
        let today = MemoryAgingReference.today
        func entry(for day: Date) -> MemoryAgedDay {
            let daysAgo = max(calendar.dateComponents([.day], from: day, to: today).day ?? 0, 0)
            let progress = HoloPaperPalette.agingProgress(daysAgo: daysAgo)
            let colors = HoloPaperPalette.agedColors(progress: progress, scheme: colorScheme)
            return MemoryAgedDay(paper: colors.paper, ink: colors.ink, quiet: colors.quiet, progress: progress)
        }
        var cache: [Date: MemoryAgedDay] = [:]
        for day in days {
            cache[day] = entry(for: day)
            // 前一天是本行纸面渐变的底色端点；章节首行还要衔住上一月尾行
            if let previous = calendar.date(byAdding: .day, value: -1, to: day) {
                cache[previous] = entry(for: previous)
            }
        }
        agingCache = cache
    }

    /// P7：该日墨色；开关关闭或进度低于可见阈值时返回 nil（行内回退原色）。
    private func agedInk(for day: Date) -> MemoryAgingInk? {
        guard agingEnabled, let entry = agingCache[day], entry.isVisible else { return nil }
        return MemoryAgingInk(ink: entry.ink, quiet: entry.quiet)
    }

    /// P7：该日纸面（顶=本日纸色，底=前一日纸色，逐日衔接成整章连续渐变）。
    /// 低于可见阈值时返回 nil（不铺背景，与现状完全一样）。
    private func agedPaperGradient(for day: Date) -> LinearGradient? {
        guard agingEnabled, let top = agingCache[day] else { return nil }
        guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
        let bottom = agingCache[previous] ?? top
        guard top.isVisible || bottom.isVisible else { return nil }
        return LinearGradient(colors: [top.paper, bottom.paper], startPoint: .top, endPoint: .bottom)
    }

    /// P7：吸顶月头的纸底（章节首行当天的纸色）；阈值之下返回 nil 保持 galleryPaper。
    private func agedHeaderPaper(_ chapter: Chapter) -> Color? {
        guard agingEnabled, let first = chapter.days.first,
              let entry = agingCache[first], entry.isVisible else { return nil }
        return entry.paper
    }

    /// P7：时间线尽头的纸面收尾——从最早一日的旧纸色渐变回纸底。
    /// 没有它，最后一行泛黄纸面会直接接上未泛黄的留白，像一条断层。
    /// 最早记录未达可见阈值（或开关关闭）时不占位，与现状完全一样。
    @ViewBuilder
    private var agedTailFade: some View {
        if agingEnabled, let oldest = recordDays.last,
           let entry = agingCache[oldest], entry.isVisible {
            LinearGradient(colors: [entry.paper, Color.galleryPaper], startPoint: .top, endPoint: .bottom)
                .padding(.horizontal, -HoloSpacing.page)
                .frame(height: MemoryAgingMetrics.tailFadeHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
            } else if eventsByDay.values.allSatisfy({ $0.isEmpty }) && selectedDay == nil {
                // 空态判断用数据源本身：分组缓存要等时间线挂载后才有人重建（见下），
                // 吃缓存会把「缓存未初始化」误判成「没有记录」（11-15 东林真机实报根因）。
                if failedModules.isEmpty {
                    // P5 #6：真·零记录空态改一句话留白（原型 03）；
                    // 动作保持原 deep link「写条想法」。
                    HoloQuietEmptyState(
                        line: "这里会慢慢\n长出你的日子。",
                        byline: "— 写下的想法、账单、打卡，会按日期出现在这里",
                        actionTitle: "写条想法",
                        action: { DeepLinkState.shared.navigate(to: .recordThought) },
                        palette: .gallery,
                        topSpacing: .flexible
                    )
                } else {
                    stateView(icon: "info.circle", title: "暂时无法载入记录",
                              message: "可以稍后再试一次。", action: ("重试", onRetry))
                }
            } else {
                timeline
            }
        }
        .background(Color.galleryPaper)
        // 分组重建挂在常驻容器上：此前挂在 timeline 内部，而 timeline 只有缓存非空才渲染
        // → onChange/onAppear 永远挂不上 → 缓存死锁在空（真机实报根因，与 1) 成对）。
        .onAppear { rebuildSections() }
        .onChange(of: dataRevision) { _, _ in rebuildSections() }
        .onChange(of: selectedDay) { _, _ in rebuildSections() }
        // P7：泛黄颜色缓存按深浅色分套，外观模式切换时整组重建
        .onChange(of: colorScheme) { _, _ in rebuildSections() }
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
                                    // P7 纸面：按天铺全宽渐变（负 padding 对冲时间线水平缩进，
                                    // 铺满屏宽不留两条边）；阈值之下无背景，与现状完全一样
                                    .background {
                                        if let gradient = agedPaperGradient(for: day) {
                                            gradient.padding(.horizontal, -HoloSpacing.page)
                                        }
                                    }
                                    // P7 墨色：注入该日墨色，行内文字经 memoryAgedInk(_:) 读取
                                    .environment(\.memoryAgingInk, agedInk(for: day))
                                    .id(day)
                            }
                        } header: {
                            // 章节上距放在吸顶头的背景之内：否则吸顶时头部上方留透明缝，
                            // 滚动中会露出上一月的节尾行（冒烟判读实抓）。
                            monthHeader(chapter, topInset: index == 0 ? 24 : 34)
                                // 阅读章节只按月头进入回写（在档坑：按行 onAppear 写 @Published
                                // 打穿 MemoryGalleryView 全量重渲染=滚动卡顿主因之一）。
                                .onAppear { syncReadingChapter(chapter) }
                        }
                    }
                    // P7：最早一行之后由旧纸色渐变回纸底，避免泛黄内容尽头露出一条生硬的分界
                    agedTailFade
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
                if let request = findDate.pendingJump {
                    jump(to: request.day, proxy: proxy)
                    findDate.pendingJump = nil
                }
            }
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

    private func monthHeader(_ chapter: Chapter, topInset: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // P4 #5：中文月份名改思源宋体（.system(design: .serif) 对中文无衬线字形，
            // 实际回退苹方）；去掉负字距（中文负字距会粘连），年份数字保持 Georgia
            Text(chapter.month.formatted(.dateTime.month(.wide)))
                .font(.holoEditorialSerif(size: monthTitleSize, bold: true))
                .foregroundStyle(Color.galleryInk)
            Text(String(calendar.component(.year, from: chapter.month)))
                .font(.custom("Georgia", size: monthTitleSize * 0.5625))
                .foregroundStyle(Color.galleryQuiet)
            Spacer(minLength: 0)
        }
        .padding(.top, topInset + 6)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(headerBackdrop(chapter))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.galleryRule).frame(height: 1)
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// P7 吸顶头纸底：与章节首行纸面同色，避免吸顶时出现异色带；
    /// 阈值之下保持 galleryPaper。
    @ViewBuilder
    private func headerBackdrop(_ chapter: Chapter) -> some View {
        if let paper = agedHeaderPaper(chapter) {
            // 负 padding 对冲时间线水平缩进，吸顶时铺满屏宽
            paper.padding(.horizontal, -HoloSpacing.page)
        } else {
            Color.galleryPaper
        }
    }

    // MARK: 日行

    private func dayRow(_ day: Date) -> some View {
        // 同日同习惯先合并成一行再拆主预览（原型 ②：戒烟 3 条 → 「×3 · 3 支」不平铺）；
        // 月历热度等仍按原始 1:1 事件计算，不受影响。
        let events = CalendarHabitDayMerger.mergeDay(eventsByDay[day] ?? [])
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
                .memoryAgedInk(.ink, accentOverride: highlighted)
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: metaSize))
                .memoryAgedInk(.quiet)
                .padding(.top, 5)
            if isToday {
                Text("今天")
                    .font(.system(size: metaSize))
                    .memoryAgedInk(.quiet)
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
                // 头图优先（04 §2：显式头图 > 旧附件 > 文字；贴纸完整显示）
                if let hero = event.heroVisualPlacement,
                   case .assetReady = hero {
                    MemoryGalleryHeroBanner(placement: hero)
                } else if let thumb = event.attachmentThumbnails.first {
                    // 等比裁切（11-15 东林实报「比例被压缩」）：定长槽位+fill+clipped，
                    // 禁用会拉伸的 aspectRatio(.fill) 直挂（在档坑：钳 fill 唯一可靠手段是定长 frame）
                    MemoryGalleryCroppedBanner(data: thumb, ratio: 1.88, cornerRadius: 9)
                        .padding(.bottom, 11)
                }
                // P4 #4：想法节选主标题改思源宋体（真正的中文衬线，黑体衬线回退问题同月份名）
                Text(event.title)
                    .font(.holoEditorialSerif(size: leadHeadlineSize, bold: true))
                    .memoryAgedInk(.ink)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                if hasBadges(event) {
                    MemoryGalleryBadgeRow(topics: event.topicBadges ?? [], tags: event.tagBadges ?? [])
                        .padding(.top, 7)
                }
                HStack(spacing: 5) {
                    Image(systemName: linearIcon(event.module))
                        .font(.system(size: 11, weight: .light))
                    Text(metaText(event))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: metaSize))
                .memoryAgedInk(.quiet)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 紧凑记录行：30pt 图标块 + 标题/元信息 + 金额或状态（缺省箭头），最小 54pt。
    /// 习惯源图标为 emoji 时直接透出（原型 ④，与习惯模块双轨渲染同口径）；
    /// 同日聚合行（habitMoments ≥ 2）轻点展开逐条时刻（原型 ②），单条行保持打开详情。
    private func recordRow(_ event: CalendarEvent) -> some View {
        let momentCount = event.habitMoments?.count ?? 0
        let isAggregated = momentCount > 1
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isAggregated {
                    withAnimation(HoloAnimation.standard) {
                        if expandedAggregations.contains(event.id) {
                            expandedAggregations.remove(event.id)
                        } else {
                            expandedAggregations.insert(event.id)
                        }
                    }
                } else {
                    onSelect(event)
                }
            } label: {
                HStack(spacing: 9) {
                    if let emoji = event.sourceIconEmoji {
                        Text(emoji)
                            .font(.system(size: 16))
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.galleryInset))
                    } else {
                        Image(systemName: linearIcon(event.module))
                            .font(.system(size: minorSize))
                            .foregroundStyle(Color.galleryAccent)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.galleryInset))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(event.title)
                                .font(.system(size: rowTitleSize, weight: .semibold,
                                              design: event.module == .thought ? .serif : .default))
                                .memoryAgedInk(.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if isAggregated {
                                Text("×\(momentCount)")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(Color.galleryAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.galleryAccent.opacity(0.12)))
                                    .overlay(Capsule().strokeBorder(Color.galleryAccent.opacity(0.26), lineWidth: 1))
                            }
                        }
                        if isAggregated {
                            HStack(spacing: 4) {
                                Text("今天 \(momentCount) 次")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(expandedAggregations.contains(event.id) ? 180 : 0))
                            }
                            .font(.system(size: metaSize))
                            .memoryAgedInk(.quiet)
                        } else if hasBadges(event) {
                            // 想法行内迷你胶囊（原型 ①）：1 主题 + 1 tag，宽行不挤
                            HStack(spacing: 5) {
                                Text(metaText(event))
                                MemoryGalleryBadgeRow(topics: event.topicBadges ?? [],
                                                      tags: event.tagBadges ?? [], compact: true)
                            }
                        } else {
                            Text(metaText(event))
                                .font(.system(size: metaSize))
                                .memoryAgedInk(.quiet)
                        }
                    }
                    Spacer(minLength: 0)
                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: rowValueSize, weight: isAggregated ? .semibold : .regular).monospacedDigit())
                            .memoryAgedInk(.ink)
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
            if isAggregated, expandedAggregations.contains(event.id), let moments = event.habitMoments {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(moments.enumerated()), id: \.offset) { _, moment in
                        HStack(spacing: 10) {
                            Text(moment.date.formatted(.dateTime.hour().minute()))
                            if let valueText = moment.valueText, !valueText.isEmpty {
                                Text(valueText)
                            }
                        }
                        .font(.system(size: 12).monospacedDigit())
                        .memoryAgedInk(.quiet)
                    }
                }
                .padding(.top, 2)
                .padding(.leading, 39)
                .padding(.bottom, 6)
            }
        }
    }

    private func hasBadges(_ event: CalendarEvent) -> Bool {
        !(event.topicBadges?.isEmpty ?? true) || !(event.tagBadges?.isEmpty ?? true)
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
/// 2026-11-15 真机三报定谳后升级：解码挪到后台线程并按显示需求降采样（ImageIO），
/// 主线程只收已解码的小位图——此前全尺寸解码发生在暖光动画首帧的主线程上，
/// 动画 1.45s 全程被解码堵死，东林看到的是「卡一下→结果直接出现」（11-15 东林实报）。
enum MemoryGalleryThumbnailCache {
    static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 48
        c.totalCostLimit = 120 * 1024 * 1024
        return c
    }()

    /// 长廊图片最大显示宽≈345pt（3x=1035px）；横幅 fill 裁切只显示图的一部分，
    /// 长边 2400 对常见手机照片/截图都保住显示区清晰度，同时把位图压回可缓存的大小。
    static let maxPixelSize = 2400

    private static func key(for data: Data) -> NSString {
        NSString(string: String(data.hashValue) + "-" + String(data.count))
    }

    /// 已解码位图的同步查询（热路径：滚动复用/重排版零解码开销）。
    static func cachedImage(for data: Data) -> UIImage? {
        cache.object(forKey: key(for: data))
    }

    /// 查缓存 → 后台解码降采样 → 入缓存。首次显示走这条：解码不再堵主线程。
    static func decodeImage(for data: Data) async -> UIImage? {
        if let cached = cachedImage(for: data) { return cached }
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            // kCGImageSourceShouldCacheImmediately 在生成缩略图时立即解码像素，
            // 后台线程把解码做完，主线程拿到的 UIImage 已是可绘制的解码位图。
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(
                      source, 0,
                      [kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                       kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
        if let decoded {
            let cost = decoded.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(decoded, forKey: key(for: data), cost: cost)
        }
        return decoded
    }
}

private struct MemoryGalleryThumbnail: View {
    let data: Data

    /// init 同步吃缓存（热路径首帧即有图）；未命中给占位色，task 后台解码完回填——
    /// 漫步首帧暖光盖着横幅，占位→回填的切换用户看不见。
    @State private var image: UIImage?

    init(data: Data) {
        self.data = data
        _image = State(initialValue: MemoryGalleryThumbnailCache.cachedImage(for: data))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.galleryInset
            }
        }
        .task(id: data) {
            image = await MemoryGalleryThumbnailCache.decodeImage(for: data)
        }
    }
}

/// 原型图标语言＝1.5pt 线性描边：长廊内把模块的 .fill 实心图标换成线性形（想法=笔）。
func linearIcon(_ module: CalendarModule) -> String {
    switch module {
    case .thought: return "pencil"
    case .finance: return "creditcard"
    case .habit: return "checkmark.circle"
    case .todo: return "checklist"
    case .health: return "heart"
    }
}

/// 想法的主题/tag 胶囊行（原型 ①）：主题=暖橙胶囊带主题 emoji，tag=中性胶囊带源色点。
/// 标准版显示 2 主题 + 2 tag（超出 +N），compact 行内迷你版只带 1 主题 + 1 tag。
struct MemoryGalleryBadgeRow: View {
    let topics: [CalendarTopicBadge]
    let tags: [CalendarTagBadge]
    var compact = false

    var body: some View {
        let shownTopics = compact ? topics.prefix(1) : topics.prefix(2)
        let shownTags = compact ? tags.prefix(1) : tags.prefix(2)
        let overflow = (topics.count - shownTopics.count) + (tags.count - shownTags.count)
        return HStack(spacing: 6) {
            ForEach(Array(shownTopics), id: \.title) { topic in
                HStack(spacing: 4) {
                    if let emoji = topic.emoji {
                        Text(emoji)
                            .font(.system(size: compact ? 10 : 11.5))
                    }
                    Text(topic.title)
                        .lineLimit(1)
                }
                .font(.system(size: compact ? 9.5 : 10.5))
                .foregroundStyle(Color.galleryAccent)
                .padding(.horizontal, compact ? 8 : 10)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.galleryAccent.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.galleryAccent.opacity(0.22), lineWidth: 1))
                .fixedSize()
            }
            ForEach(Array(shownTags), id: \.name) { tag in
                HStack(spacing: 4) {
                    Circle()
                        .fill(tagDotColor(tag.colorHex))
                        .frame(width: 5, height: 5)
                    Text(tag.name)
                        .lineLimit(1)
                }
                .font(.system(size: compact ? 9.5 : 10))
                .foregroundStyle(Color.galleryQuiet)
                .padding(.horizontal, compact ? 7 : 9)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.galleryQuiet.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.galleryQuiet.opacity(0.2), lineWidth: 1))
                .fixedSize()
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.galleryQuiet)
            }
        }
    }

    /// tag 源色（ThoughtTag.color 十六进制）；无色回落长廊次级色
    private func tagDotColor(_ hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return .galleryQuiet }
        return Color(hex: hex)
    }
}

/// 等比裁切横幅：GeometryReader 定长槽位 + scaledToFill + clipped（不拉伸、不压比例）。
struct MemoryGalleryCroppedBanner: View {
    let data: Data
    let ratio: CGFloat
    var cornerRadius: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            MemoryGalleryThumbnail(data: data)
                .frame(width: geo.size.width, height: geo.size.width / ratio)
                .clipped()
        }
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
