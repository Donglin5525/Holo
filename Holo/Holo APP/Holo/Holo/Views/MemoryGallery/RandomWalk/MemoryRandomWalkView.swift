//
//  MemoryRandomWalkView.swift
//  Holo
//
//  随机漫步面板内容（暖光规格 §2「漫步抵达页」）：
//  - 固定标题「随机漫步」+ 右侧「关闭」；标题不参与暖光淡出
//  - 结果区与暖光区复用同一内容矩形；显示区不足时结果正文单独滚动
//  - 日期区、最多 3 条记录预览、回看一句、底部「再走一天 / 在长廊看这天」
//  - 空态 / 加载（>200ms 提示）/ 失败重试直接呈现
//

import SwiftUI

struct MemoryRandomWalkView: View {
    @ObservedObject var session: MemoryRandomWalkSession
    let calendar: Calendar
    /// 关闭漫步：整个面板一起收起，恢复长廊原锚点。
    let onClose: () -> Void
    /// 「在长廊看这天」：定位长廊到抵达日并收起面板。
    let onOpenInGallery: (Date) -> Void
    /// 点开一条原记录（详情弹层或想法深链由宿主决定）。
    let onOpenEvent: (CalendarEvent) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var accessibilityNamespace
    @AccessibilityFocusState private var axFocus: WalkAxiosFocus?

    enum WalkAxiosFocus {
        case arrivalDate
    }

    /// 加载提示的防闪门槛（§2：等待超过 200ms 显示；短请求不闪状态）。
    // 原型即契约：固定字号（px→pt 1:1），不随系统 Dynamic Type 缩放（东林真机实报定谳）。
    private let walkDateSize: CGFloat = 41.6
    private let rowTitleSize: CGFloat = 15
    private let metaSize: CGFloat = 12
    private let rowValueSize: CGFloat = 14
    private let echoTextSize: CGFloat = 16
    private let actionSize: CGFloat = 14
    @State private var loadingShown = false
    @State private var loadingTimer: Task<Void, Never>?
    /// 原型 is-arriving 的上浮淡入（walk-reveal）：抵达瞬间记录列表 250ms ease-out、
    /// 回看一句延迟 45ms 再 280ms；新一次旅行开始时复位。
    @State private var revealRecords = false
    @State private var revealEcho = false

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.phase == .arrived { actions }
        }
        .background(Color.gallerySurface)
        .onChange(of: scenePhase) { _, phase in
            session.handleScenePhase(phase)
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .arrived {
                axFocus = .arrivalDate
                withAnimation(.easeOut(duration: 0.25)) { revealRecords = true }
                withAnimation(.easeOut(duration: 0.28).delay(0.045)) { revealEcho = true }
            } else if phase == .traveling || phase == .loading {
                revealRecords = false
                revealEcho = false
            }
            configureLoadingTimer(phase)
        }
        .onAppear {
            configureLoadingTimer(session.phase)
            if session.phase == .arrived {
                revealRecords = true
                revealEcho = true
            }
        }
        .onDisappear {
            loadingTimer?.cancel()
        }
    }

    // MARK: - 标题行（不参与暖光淡出）

    /// 原型 dialog-head 1:1：衬线标题 700/20pt + 「关闭」+ 底部细线（padding 13/0/9）。
    private var header: some View {
        HStack(spacing: 12) {
            Text("随机漫步")
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(Color.galleryInk)
            Spacer()
            Button {
                session.close()
                onClose()
            } label: {
                Text("关闭")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.galleryAccent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("memoryWalk.close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 13)
        .padding(.bottom, 9)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.galleryRule)
            .frame(height: 1)
            .padding(.horizontal, 20)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:
            loadingView
        case .loading:
            // 「再走一天」取数期间旧抵达页继续显示（§3：旧页可在加载时继续显示），首次才给加载态。
            if let arrival = session.arrival {
                arrivalPage(arrival)
            } else {
                loadingView
            }
        case .traveling, .landing, .arrived:
            if let arrival = session.arrival {
                arrivalPage(arrival)
            } else {
                loadingView
            }
        case .empty:
            emptyView
        case .failed(let message):
            failedView(message)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            if loadingShown {
                ProgressView()
                    .tint(Color.galleryAccent)
                Text("正在找一段旧日记录")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.galleryQuiet)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 原型 walk-empty：左对齐衬线标题 700/24pt + 15pt 说明（padding 32/0/17）。
    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有可漫步的旧日")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(Color.galleryInk)
            Text("长廊里有了更早的记录，就可以回来走走")
                .font(.system(size: 15))
                .lineSpacing(6)
                .foregroundStyle(Color.galleryQuiet)
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(Color.galleryInk)
            Button {
                session.start()
            } label: {
                Text("重试")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.galleryAccent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.galleryInset))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.galleryRule, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 9)
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 抵达页

    private func arrivalPage(_ arrival: MemoryRandomWalkSession.Arrival) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                dateZone(arrival)
                recordZone(arrival)
                    .opacity(revealRecords || session.phase != .arrived ? 1 : 0)
                    .offset(y: revealRecords || session.phase != .arrived ? 0 : 6)
                if let echo = arrival.echo {
                    echoCard(echo, arrival: arrival)
                        .padding(.top, 13)
                        .opacity(revealEcho || session.phase != .arrived ? 1 : 0)
                        .offset(y: revealEcho || session.phase != .arrived ? 0 : 6)
                }
            }
            .padding(.horizontal, 20)
            // 底部留足滚动余量：动作区上沿渐隐层不裁记录行的副标题（冒烟实抓第三行被裁半）
            .padding(.bottom, 36)
            .accessibilityHidden(session.phase != .arrived)
        }
        .overlay {
            // 暖光过场：结果页先排版好，过场层淡出后自然露出（§4.1 图层顺序）。
            if session.phase == .traveling || session.phase == .landing,
               let elapsed = session.elapsedProvider,
               let arrival = session.arrival {
                MemoryWarmLightTransition(
                    departure: departureStamp(arrival),
                    arrival: arrivalStamp(arrival),
                    timeline: WarmLightTimeline(reduceMotion: session.reduceMotion),
                    elapsed: elapsed)
            }
        }
        .clipped()
    }

    private func departureStamp(_ arrival: MemoryRandomWalkSession.Arrival) -> MemoryWarmLightTransition.StampContent {
        MemoryWarmLightTransition.StampContent(
            label: arrival.isDepartureToday ? "今天" : "出发",
            yearText: yearText(arrival.departureDay),
            dateText: dateText(arrival.departureDay),
            excerpt: nil)
    }

    private func arrivalStamp(_ arrival: MemoryRandomWalkSession.Arrival) -> MemoryWarmLightTransition.StampContent {
        MemoryWarmLightTransition.StampContent(
            label: "想起那一天",
            yearText: yearText(arrival.day),
            dateText: dateText(arrival.day),
            excerpt: arrival.excerpt)
    }

    private func yearText(_ day: Date) -> String {
        String(format: "%d 年", calendar.component(.year, from: day))
    }

    private func dateText(_ day: Date) -> String {
        let comps = calendar.dateComponents([.month, .day], from: day)
        return String(format: "%d 月 %d 日", comps.month ?? 0, comps.day ?? 0)
    }

    private func weekdayText(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.abbreviated))
    }

    /// 原型 walk-date 1:1：meta 13pt quiet → 衬线日期 650/41.6pt（字距 -0.06em）→ 距离 13pt accent；
    /// 上 23 / 下 19 + 底部细线。
    private func dateZone(_ arrival: MemoryRandomWalkSession.Arrival) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(yearText(arrival.day) + " · " + weekdayText(arrival.day))
                .font(.system(size: 13))
                .foregroundStyle(Color.galleryQuiet)
            Text(dateText(arrival.day))
                .font(.system(size: walkDateSize, weight: .semibold, design: .serif))
                .tracking(-0.06 * walkDateSize)
                .foregroundStyle(Color.galleryInk)
                .padding(.top, 4)
                .padding(.bottom, 7)
                .accessibilityIdentifier("memoryWalk.arrivalDate")
                // 旁白读完整日期（§3：焦点落到「2026 年 5 月 21 日，星期四」）
                .accessibilityLabel(arrival.day.formatted(.dateTime.year().month().day().weekday(.wide)))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($axFocus, equals: .arrivalDate)
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                Text("距今天 \(arrival.distanceDays) 天")
                    .font(.system(size: 13))
            }
            .foregroundStyle(Color.galleryAccent)
        }
        .padding(.top, 23)
        .padding(.bottom, 19)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.galleryRule).frame(height: 1)
        }
    }

    // MARK: - 记录区

    /// 原型 walk-records 1:1：上距 15；记录行=原型 .record（36pt inset 图标块 + 标题 15pt +
    /// 「模块 · 时间」12pt quiet + 右侧数值 14pt ink），行间 1px 细线，无卡片底。
    private func recordZone(_ arrival: MemoryRandomWalkSession.Arrival) -> some View {
        let previews = Array(Self.orderedPreviews(for: arrival.events).prefix(3))
        let total = arrival.events.count
        return VStack(alignment: .leading, spacing: 0) {
            Text(total > previews.count ? "那天的记录 · \(total)" : "那天的记录")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.galleryQuiet)
                .padding(.bottom, 4)
            ForEach(Array(previews.enumerated()), id: \.element.id) { index, event in
                recordRow(event)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(Color.galleryRule).frame(height: 1)
                        }
                    }
            }
            if total > previews.count {
                Button {
                    onOpenInGallery(arrival.day)
                } label: {
                    HStack(spacing: 4) {
                        Text(session.indexIncomplete ? "在长廊看这天" : "在长廊看全部 \(total) 条")
                            .font(.system(size: 13))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.galleryAccent)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("memoryWalk.openAll")
            }
        }
        .padding(.top, 15)
    }

    private func recordRow(_ event: CalendarEvent) -> some View {
        Button {
            onOpenEvent(event)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // 想法附件：约 2.45:1 横幅（§2：图片来自所点想法）
                if let thumb = event.attachmentThumbnails.first {
                    WarmWalkThumbnail(data: thumb)
                        .aspectRatio(2.45, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .padding(.top, 8)
                }
                HStack(spacing: 9) {
                    Image(systemName: event.module.iconName)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.galleryAccent)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.galleryInset))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.system(size: rowTitleSize, weight: .medium))
                            .foregroundStyle(Color.galleryInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(event.module.displayName + " · " + (event.hasReliableTime
                             ? event.date.formatted(.dateTime.hour().minute())
                             : String(localized: "当天")))
                            .font(.system(size: 12))
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
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

/// 会话暴露的排序（可靠时刻升序、无可靠置后、摘句来源想法保前三）。
static func orderedPreviews(for events: [CalendarEvent]) -> [CalendarEvent] {
    MemoryRandomWalkSession.orderedPreviews(for: events)
}

/// 附件缩略图（UIKit/AppKit 双端；数据缺失时留空不占位）。
private struct WarmWalkThumbnail: View {
    let data: Data

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.clear
        }
        #else
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color.clear
        }
        #endif
    }
}

    // MARK: - 回看一句

    /// 原型 walk-reading 1:1：inset 底 + 左 2px 橙线 + 右侧 12pt 圆角；
    /// 内边距 上12/右13/下11/左14；标签 12pt 650 accent、正文衬线 600/16pt 行高 1.65、来源 12pt quiet。
    private func echoCard(_ echo: MemoryWalkEcho, arrival: MemoryRandomWalkSession.Arrival) -> some View {
        Button {
            if let id = echo.sourceEventID,
               let event = arrival.events.first(where: { $0.id == id }) {
                onOpenEvent(event)
            } else {
                onOpenInGallery(arrival.day)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text("回看一句")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.galleryAccent)
                Text(echo.text)
                    .font(.system(size: echoTextSize, weight: .semibold, design: .serif))
                    .lineSpacing(echoTextSize * 0.65)
                    .foregroundStyle(Color.galleryInk)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                HStack(spacing: 4) {
                    Text("查看这句的来源")
                        .font(.system(size: 12))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.galleryQuiet)
            }
            .padding(.top, 12)
            .padding(.trailing, 13)
            .padding(.bottom, 11)
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.galleryInset)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                              bottomTrailingRadius: 12, topTrailingRadius: 12,
                                              style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.galleryOrange)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memoryWalk.readingSource")
    }

    // MARK: - 底部动作

    /// 原型 walk-actions 1:1：顶部细线、padding 9/0/14、两端对齐；
    /// 「再走一天」= inset 底 + 细线描边 + accent 字（圆角 12）；「在长廊看这天」= accent 文字钮。
    private var actions: some View {
        HStack(spacing: 12) {
            if session.knownDayCount > 1 || session.visited.count > 1 {
                Button {
                    if session.allSeen {
                        session.requestRestart()
                    } else {
                        session.start()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 12, weight: .semibold))
                        Text(session.allSeen ? "重新漫步" : "再走一天")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(Color.galleryAccent)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.galleryInset))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.galleryRule, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("memoryWalk.next")
            }
            Spacer(minLength: 0)
            Button {
                if let day = session.arrival?.day {
                    onOpenInGallery(day)
                }
            } label: {
                HStack(spacing: 5) {
                    Text("在长廊看这天")
                        .font(.system(size: 14))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.galleryAccent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memoryWalk.openDay")
        }
        .padding(.horizontal, 20)
        .padding(.top, 9)
        .padding(.bottom, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.galleryRule).frame(height: 1).padding(.horizontal, 20)
        }
    }

    // MARK: - 加载提示防闪（>200ms 才显示文案）

    private func configureLoadingTimer(_ phase: MemoryRandomWalkSession.Phase) {
        loadingTimer?.cancel()
        if phase == .loading {
            loadingShown = false
            loadingTimer = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                loadingShown = true
            }
        } else {
            loadingShown = false
        }
    }
}
