// 我的积累：个人页与长廊共用的成长总览。
import SwiftUI

struct HoloGrowthView: View {
    @ObservedObject var service: HoloGrowthService = .shared
    @State private var showRules = false
    @State private var nextMetric: HoloGrowthMetric?
    @State private var selectedEvent: HoloGrowthMilestone?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onOpenModule: @MainActor @Sendable (DeepLinkTarget) -> Void

    init(service: HoloGrowthService? = nil, onOpenModule: @escaping @MainActor @Sendable (DeepLinkTarget) -> Void = { DeepLinkState.shared.navigate(to: $0) }) {
        self.service = service ?? .shared
        self.onOpenModule = onOpenModule
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                if service.snapshot == nil || service.isDownloading || service.errorMessage != nil {
                    HoloGrowthStatusView(service: service)
                }
                if let snapshot = service.snapshot {
                    HoloGrowthHero(days: snapshot.recordedDays)
                    metricList(snapshot)
                    if let next = stableNext(snapshot) {
                        NavigationLink {
                            HoloGrowthMetricView(metric: next.metric, service: service, onOpenModule: onOpenModule)
                        } label: { HoloGrowthNextStop(progress: next) }
                        .buttonStyle(.plain)
                    } else if snapshot.recordedDays == 0 {
                        firstRecord
                    }
                    history
                    Button { showRules = true } label: {
                        Text("根据现有记录统计 · 查看口径")
                            .holoText(.metadata)
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            .padding(HoloSpacing.page)
            .holoContentColumn(paintsBackground: false)
        }
        .background(Color.holoToolBackground)
        .navigationTitle("我的积累")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showRules = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("积累统计说明")
            }
        }
        .sheet(isPresented: $showRules) { HoloGrowthRulesView(service: service) }
        .sheet(item: $selectedEvent) { event in
            NavigationStack { HoloGrowthMilestoneView(event: event, service: service) }
        }
        .task {
            await service.refresh()
            if nextMetric == nil { nextMetric = service.snapshot?.next?.metric }
        }
        .refreshable { await service.refresh() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: service.snapshot?.recordedDays)
        .accessibilityIdentifier("growth.overview")
    }

    private func stableNext(_ snapshot: HoloGrowthSnapshot) -> HoloGrowthProgress? {
        if let nextMetric {
            let value = snapshot.value(nextMetric)
            if value.count > 0 && value.nextThreshold != nil { return value }
        }
        return snapshot.next
    }

    private func metricList(_ snapshot: HoloGrowthSnapshot) -> some View {
        let used = snapshot.progress.filter { $0.count > 0 }
        let visible = used.isEmpty ? snapshot.progress : used
        return VStack(spacing: 0) {
            ForEach(visible) { progress in
                metricLink(progress)
                if progress.id != visible.last?.id { Divider() }
            }
            if !used.isEmpty && used.count < snapshot.progress.count {
                Divider()
                DisclosureGroup("还有这些积累方式") {
                    ForEach(snapshot.progress.filter { $0.count == 0 }) { metricLink($0) }
                }
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.vertical, 12)
            }
        }
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func metricLink(_ progress: HoloGrowthProgress) -> some View {
        NavigationLink {
            HoloGrowthMetricView(metric: progress.metric, service: service, onOpenModule: onOpenModule)
        } label: { HoloGrowthMetricRow(progress: progress) }
        .buttonStyle(.plain)
        .accessibilityIdentifier("growth.metric.\(progress.metric.rawValue)")
    }

    private var firstRecord: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每一种开始，都值得")
                .holoText(.metadata).foregroundStyle(Color.holoToolAction)
            Text("留下你的第一条记录").holoText(.sectionTitle)
            Text("一笔账、一个念头，或一次习惯打卡。")
                .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
            Button("记录一笔") { onOpenModule(.addTransaction) }
                .buttonStyle(HoloActionStyle(role: .secondary))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolAction.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(service.milestones.isEmpty ? "未来的里程碑" : "走过的里程碑").holoText(.body).fontWeight(.semibold)
                Spacer()
                if service.milestones.count > 3 {
                    NavigationLink { HoloGrowthHistoryView(service: service) } label: {
                        Text("查看全部").holoText(.metadata)
                            .frame(minWidth: 60, minHeight: 44).contentShape(Rectangle())
                    }.foregroundStyle(Color.holoToolTextSecondary)
                }
            }
            if service.milestones.isEmpty {
                Text("等你开始，这里会慢慢丰富起来。")
                    .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
            }
            ForEach(Array(service.milestones.prefix(3))) { event in
                Button { selectedEvent = event } label: { HoloGrowthMilestoneRow(event: event) }
                    .buttonStyle(.plain)
            }
        }
    }
}

struct HoloGrowthHero: View {
    let days: Int
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 64
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("日子里的小小积累").holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
            if days == 0 {
                Text("从第一笔开始积累").holoText(.pageTitle)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("记录了").holoText(.pageTitle)
                        Text(days.formatted()).font(.system(size: numberSize, weight: .regular, design: .serif)).contentTransition(.numericText())
                        Text("天").holoText(.sectionTitle)
                    }
                    Text("累计记录 \(days) 天").holoText(.pageTitle)
                }
            }
            Text(days == 0 ? "不用做很多，留下一点就很好。" : "那些看似平常的日子，都留下了痕迹。")
                .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

struct HoloGrowthMetricRow: View {
    let progress: HoloGrowthProgress
    var showChevron = true
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                symbol
                Text(progress.metric.title).holoText(.body)
                Spacer(minLength: 12)
                value
                if showChevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.holoToolTextSecondary) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(progress.metric.title, systemImage: progress.metric.icon).holoText(.body)
                value
            }
        }
        .foregroundStyle(Color.holoToolText)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.metric.title) \(progress.count) \(progress.metric.unit)")
    }
    private var value: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(progress.count.formatted()).holoText(.amount).monospacedDigit()
            Text(progress.metric.unit).holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
        }
    }
    private var symbol: some View {
        Image(systemName: progress.metric.icon)
            .font(.system(size: 18)).foregroundStyle(Color.holoToolTextSecondary)
            .frame(width: 36, height: 36)
            .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }
}

struct HoloGrowthNextStop: View {
    let progress: HoloGrowthProgress
    var body: some View {
        if let target = progress.nextThreshold {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("下一站").holoText(.metadata)
                    Spacer()
                    Image(systemName: "flag").accessibilityHidden(true)
                }.foregroundStyle(Color.holoToolAction)
                Text(progress.metric.milestoneTitle(target)).holoText(.sectionTitle)
                Text("还差 \(target - progress.count) \(progress.metric.unit)，慢慢积累就好。")
                    .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                ProgressView(value: Double(progress.count), total: Double(target))
                    .tint(Color.holoToolAction)
                    .accessibilityLabel("\(progress.metric.title)，下一站 \(target) \(progress.metric.unit)")
                HStack {
                    Text("\(progress.count) / \(target) \(progress.metric.unit)")
                    Spacer()
                    if progress.metric != .thought { Text("不需要连续") }
                }.holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
            }
            .padding(20)
            .background(Color.holoToolAction.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
    }
}

struct HoloGrowthStatusView: View {
    @ObservedObject var service: HoloGrowthService = .shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if service.isDownloading {
                Label("正在同步，积累会在同步后更新", systemImage: "icloud.and.arrow.down")
                    .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
            } else if service.snapshot == nil && service.errorMessage == nil {
                ProgressView("正在整理你的积累").holoText(.supporting)
            }
            if let message = service.errorMessage {
                Text(message).holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                Button("重试") { Task { await service.refresh() } }.frame(minHeight: 44)
            }
        }
    }
}

struct HoloGrowthEntryView: View {
    @ObservedObject var service: HoloGrowthService = .shared
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("我的积累", systemImage: "leaf").holoText(.body).fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.holoToolTextSecondary)
            }
            if let snapshot = service.snapshot {
                let used = snapshot.progress.filter { $0.count > 0 }
                if used.isEmpty {
                    Text("每一次记录，都从这里开始。")
                        .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                } else if compact {
                    Text("已记录 \(snapshot.recordedDays) 天 · 查看积累")
                        .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(used) { progress in entryNumber(progress) }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(used) { progress in entryNumber(progress) }
                        }
                    }
                    if let event = service.milestones.first {
                        Divider()
                        Label(event.title, systemImage: event.metric.icon)
                            .holoText(.metadata).foregroundStyle(Color.holoToolAction)
                    }
                }
            } else {
                Text(service.errorMessage == nil ? "正在整理你的积累" : "暂时没能整理积累，点此重试")
                    .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
            }
        }
        .padding(compact ? 12 : 20)
        .foregroundStyle(Color.holoToolText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
        .contentShape(Rectangle())
        .accessibilityIdentifier("growth.entry")
    }
    private func entryNumber(_ progress: HoloGrowthProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(progress.count.formatted()).holoText(.amount).monospacedDigit()
                Text(progress.metric.unit).holoText(.metadata)
            }
            Text(progress.metric.title).holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
