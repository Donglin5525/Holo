// 积累详情、历史和口径说明，所有数字读取同一个共享快照。
import SwiftUI

struct HoloGrowthMetricView: View {
    let metric: HoloGrowthMetric
    @ObservedObject var service: HoloGrowthService = .shared
    var onOpenModule: (@MainActor @Sendable (DeepLinkTarget) -> Void)?
    @State private var selectedEvent: HoloGrowthMilestone?

    init(metric: HoloGrowthMetric, service: HoloGrowthService? = nil,
         onOpenModule: (@MainActor @Sendable (DeepLinkTarget) -> Void)? = nil) {
        self.metric = metric
        self.service = service ?? .shared
        self.onOpenModule = onOpenModule
    }


    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                if service.snapshot == nil || service.isDownloading || service.errorMessage != nil {
                    HoloGrowthStatusView(service: service)
                }
                if let snapshot = service.snapshot {
                    let progress = snapshot.value(metric)
                    Text("日子里的小小积累").holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
                    HoloGrowthMetricRow(progress: progress, showChevron: false)
                    Text("沿途的里程碑").holoText(.body).fontWeight(.semibold)
                    VStack(spacing: 0) {
                        ForEach(metric.thresholds, id: \.self) { threshold in
                            let event = service.milestones.first { $0.metric == metric && $0.threshold == threshold }
                            HStack(spacing: 12) {
                                Image(systemName: event == nil ? "circle" : "checkmark.circle.fill")
                                    .foregroundStyle(event == nil ? Color.holoToolTextSecondary : Color.holoToolAction)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(metric.milestoneTitle(threshold)).holoText(.body)
                                    if let event {
                                        Text(HoloGrowthDateText.event(event)).holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
                                    } else {
                                        Text("\(min(progress.count, threshold)) / \(threshold) \(metric.unit)")
                                            .holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if let event {
                                    Button { selectedEvent = event } label: {
                                        Text("查看").holoText(.metadata)
                                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                    }
                                        .accessibilityLabel("查看\(event.title)")
                                }
                            }
                            .padding(.vertical, 12)
                            if threshold != metric.thresholds.last { Divider() }
                        }
                    }
                    Text(metric.explanation).holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                    Text("不要求连续。归档保留积累，删除或撤销会调整当前数字；已经达成的里程碑保留为历史。")
                        .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                    NavigationLink { HoloGrowthDatesView(metric: metric, service: service) } label: {
                        Text("查看积累日期").frame(minHeight: 44).contentShape(Rectangle())
                    }
                    if let onOpenModule {
                        Button(moduleLabel) { onOpenModule(moduleTarget) }
                            .buttonStyle(HoloActionStyle(role: .secondary))
                    }
                }
            }
            .padding(HoloSpacing.page)
            .holoContentColumn(paintsBackground: false)
        }
        .foregroundStyle(Color.holoToolText)
        .background(Color.holoToolBackground)
        .navigationTitle(metric.title)
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $selectedEvent) { event in NavigationStack { HoloGrowthMilestoneView(event: event, service: service) } }
        .accessibilityIdentifier("growth.detail.\(metric.rawValue)")
    }

    private var moduleLabel: String {
        switch metric { case .finance: return "打开记账"; case .thought: return "记录一个想法"; case .habit: return "打开习惯" }
    }
    private var moduleTarget: DeepLinkTarget {
        switch metric { case .finance: return .finance; case .thought: return .recordThought; case .habit: return .habits }
    }
}

struct HoloGrowthDatesView: View {
    let metric: HoloGrowthMetric
    @ObservedObject var service: HoloGrowthService = .shared
    var body: some View {
        List {
            if let snapshot = service.snapshot {
                let grouped = Dictionary(grouping: snapshot.value(metric).dates, by: { $0 })
                ForEach(grouped.keys.sorted(by: >), id: \.self) { date in
                    HStack {
                        Text(HoloGrowthDateText.date(date))
                        Spacer()
                        Text(metric == .thought ? "\(grouped[date]?.count ?? 0) 条想法" : "已记录")
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("积累日期")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct HoloGrowthHistoryView: View {
    @ObservedObject var service: HoloGrowthService = .shared
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(service.milestones) { event in
                    NavigationLink { HoloGrowthMilestoneView(event: event, service: service) } label: { HoloGrowthMilestoneRow(event: event) }
                        .buttonStyle(.plain)
                }
            }
            .padding(HoloSpacing.page)
            .holoContentColumn(paintsBackground: false)
        }
        .background(Color.holoToolBackground)
        .navigationTitle("走过的里程碑")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct HoloGrowthMilestoneRow: View {
    let event: HoloGrowthMilestone
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: event.metric.icon)
                .foregroundStyle(Color.holoToolAction)
                .frame(width: 40, height: 40)
                .background(Color.holoToolInset, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(event.title).holoText(.supporting).foregroundStyle(Color.holoToolText)
                Text(HoloGrowthDateText.event(event)).holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct HoloGrowthMilestoneView: View {
    let event: HoloGrowthMilestone
    @ObservedObject var service: HoloGrowthService = .shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                Text("一个值得记住的小节点").holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
                Image(systemName: event.metric.icon)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Color.holoToolAction)
                    .frame(width: 90, height: 90)
                    .background(Color.holoToolAction.opacity(0.07), in: Circle())
                    .accessibilityHidden(true)
                Text(event.title).holoText(.pageTitle).multilineTextAlignment(.center)
                Text("每一次小小的记录，都留下了痕迹。")
                    .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                Text(HoloGrowthDateText.event(event)).holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
                if let current = service.snapshot?.value(event.metric), current.count < event.threshold {
                    Text("你曾经达成这个里程碑。当前积累为 \(current.count) \(event.metric.unit)，已随记录调整。")
                        .holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                }
                NavigationLink { HoloGrowthMetricView(metric: event.metric, service: service) } label: {
                    Text("查看这项积累").frame(minHeight: 44).contentShape(Rectangle())
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .holoContentColumn(paintsBackground: false)
        }
        .background(Color.holoToolBackground)
        .foregroundStyle(Color.holoToolText)
        .toolbar { ToolbarItem(placement: HoloToolbarPlacement.topBarTrailing) { Button("关闭") { dismiss() } } }
        .accessibilityIdentifier("growth.milestone")
    }
}

struct HoloGrowthRulesView: View {
    @ObservedObject var service: HoloGrowthService = .shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("这些数字，怎么算？") {
                    Text("累计记录天数：记账、想法和正向打卡型习惯所覆盖日期的并集。同一天有多种记录，也只算一天；它不表示连续使用天数。")
                    ForEach(HoloGrowthMetric.allCases) { metric in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(metric.title).fontWeight(.medium)
                            Text(metric.explanation).foregroundStyle(Color.holoToolTextSecondary)
                        }
                    }
                }
                Section("真实的积累") {
                    Text("补记与导入按原记录日期计算，不会把过去的积累写成今天的坚持。未来日期暂不计入。")
                    Text("归档保留积累，删除会调整当前数字。已经达成的里程碑保留为历史，不会反复颁发；全量清空数据会同时清除里程碑。")
                    Text("日期沿用各模块的业务时间和当前日历规则。较早记录未保存原始时区，跨时区查看时可能存在日期归属差异。")
                }
                Section {
                    Toggle("里程碑提醒", isOn: Binding(get: { service.remindersEnabled }, set: { enabled in
                        Task { await service.setRemindersEnabled(enabled) }
                    }))
                    Text("达成时轻轻提醒，不发送系统推送。关闭后仍会保存里程碑。")
                        .holoText(.metadata).foregroundStyle(Color.holoToolTextSecondary)
                    if let message = service.errorMessage { Text(message).foregroundStyle(Color.holoToolError) }
                }
            }
            .navigationTitle("积累统计说明")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: HoloToolbarPlacement.topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

nonisolated enum HoloGrowthDateText {
    static func date(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月 d 日"
        return formatter.string(from: value)
    }
    static func event(_ event: HoloGrowthMilestone) -> String {
        event.achievedAt.map(date) ?? "首次统计时已达成"
    }
}
