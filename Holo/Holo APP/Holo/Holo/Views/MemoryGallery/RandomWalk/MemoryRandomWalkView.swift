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
    @State private var loadingShown = false
    @State private var loadingTimer: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.phase == .arrived { actions }
        }
        .background(Color.holoToolBackground)
        .onChange(of: scenePhase) { _, phase in
            session.handleScenePhase(phase)
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .arrived {
                axFocus = .arrivalDate
            }
            configureLoadingTimer(phase)
        }
        .onAppear {
            configureLoadingTimer(session.phase)
        }
        .onDisappear {
            loadingTimer?.cancel()
        }
    }

    // MARK: - 标题行（不参与暖光淡出）

    private var header: some View {
        HStack(spacing: 12) {
            Text("随机漫步")
                .font(.headline)
            Spacer()
            Button {
                session.close()
                onClose()
            } label: {
                Text("关闭")
                    .font(.subheadline)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("memoryWalk.close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 7)
        .padding(.bottom, 9)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.holoToolBorder.opacity(0.6))
            .frame(height: 0.5)
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
                Text("正在找一段旧日记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "sun.min")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("还没有可漫步的旧日")
                .font(.headline)
            Text("长廊里有了更早的记录，就可以回来走走")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("重试") { session.start() }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 抵达页

    private func arrivalPage(_ arrival: MemoryRandomWalkSession.Arrival) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dateZone(arrival)
                recordZone(arrival)
                if let echo = arrival.echo {
                    echoCard(echo, arrival: arrival)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 23)
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
        let symbols = calendar.veryShortWeekdaySymbols
        return symbols[(calendar.component(.weekday, from: day) - 1 + 6) % 7]
    }

    private func dateZone(_ arrival: MemoryRandomWalkSession.Arrival) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(yearText(arrival.day) + " · " + weekdayText(arrival.day))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(dateText(arrival.day))
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                .accessibilityIdentifier("memoryWalk.arrivalDate")
                // 旁白读完整日期（§3：焦点落到「2026 年 5 月 21 日，星期四」）
                .accessibilityLabel(arrival.day.formatted(.dateTime.year().month().day().weekday(.wide)))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($axFocus, equals: .arrivalDate)
            Text("距今天 \(arrival.distanceDays) 天")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 记录区

    private func recordZone(_ arrival: MemoryRandomWalkSession.Arrival) -> some View {
        let previews = Array(Self.orderedPreviews(for: arrival.events).prefix(3))
        let total = arrival.events.count
        return VStack(alignment: .leading, spacing: 8) {
            Text(total > previews.count ? "那天的记录 · \(total)" : "那天的记录")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(previews) { event in
                    recordRow(event)
                }
            }
            .background(Color.holoToolSurface)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
            if total > previews.count {
                Button {
                    onOpenInGallery(arrival.day)
                } label: {
                    Text(session.indexIncomplete ? "在长廊看这天" : "在长廊看全部 \(total) 条")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.holoPrimary)
                .accessibilityIdentifier("memoryWalk.openAll")
            }
        }
    }

    private func recordRow(_ event: CalendarEvent) -> some View {
        Button {
            onOpenEvent(event)
        } label: {
            HStack(spacing: 10) {
                if let thumb = event.attachmentThumbnails.first {
                    WarmWalkThumbnail(data: thumb)
                        .frame(width: 58, height: 24)   // ≈2.45:1
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(event.module.displayName)
                        Text("·")
                        Text(event.hasReliableTime
                             ? event.date.formatted(.dateTime.hour().minute())
                             : "当天")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
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

    private func echoCard(_ echo: MemoryWalkEcho, arrival: MemoryRandomWalkSession.Arrival) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("回看一句")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.warmLightAccent)
                Spacer()
            }
            Text(echo.text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let id = echo.sourceEventID,
                   let event = arrival.events.first(where: { $0.id == id }) {
                    onOpenEvent(event)
                } else {
                    onOpenInGallery(arrival.day)
                }
            } label: {
                Text("查看这句的来源 ›")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.holoPrimary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("memoryWalk.readingSource")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.warmLightPaper)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.holoPrimary)
                .frame(width: 2)
        }
    }

    // MARK: - 底部动作

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
                    Text(session.allSeen ? "重新漫步" : "再走一天")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("memoryWalk.next")
            }
            Button {
                if let day = session.arrival?.day {
                    onOpenInGallery(day)
                }
            } label: {
                Text("在长廊看这天")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("memoryWalk.openDay")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
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
