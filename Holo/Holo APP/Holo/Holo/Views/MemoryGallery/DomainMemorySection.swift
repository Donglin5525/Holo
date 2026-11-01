//
//  DomainMemorySection.swift
//  Holo
//
//  记忆长廊里的用户可理解记忆中心。
//

import SwiftUI

enum HoloMemoryDisplayGroup: String, CaseIterable, Identifiable {
    case profile
    case finance
    case thought
    case health
    case habit
    case task
    case goal
    case conversation
    case crossDomain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: return String(localized: "关于你")
        case .finance: return String(localized: "财务")
        case .thought: return String(localized: "想法")
        case .health: return String(localized: "健康")
        case .habit: return String(localized: "习惯")
        case .task: return String(localized: "任务")
        case .goal: return String(localized: "目标")
        case .conversation: return String(localized: "对话")
        case .crossDomain: return String(localized: "综合观察")
        }
    }

    var icon: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .finance: return "wallet.bifold"
        case .thought: return "quote.bubble"
        case .health: return "heart"
        case .habit: return "repeat"
        case .task: return "checkmark.circle"
        case .goal: return "flag"
        case .conversation: return "bubble.left.and.bubble.right"
        case .crossDomain: return "point.3.connected.trianglepath.dotted"
        }
    }

    static func group(for record: HoloMemoryRecord) -> HoloMemoryDisplayGroup? {
        if record.scope == .crossDomain { return .crossDomain }
        switch record.primaryDomain {
        case .profile: return .profile
        case .finance: return .finance
        case .thought: return .thought
        case .health: return .health
        case .habit: return .habit
        case .task: return .task
        case .goal: return .goal
        case .conversation: return .conversation
        case nil: return nil
        }
    }
}

extension HoloMemoryDomain {
    var userFacingName: String {
        switch self {
        case .finance: return String(localized: "财务")
        case .thought: return String(localized: "想法")
        case .health: return String(localized: "健康")
        case .habit: return String(localized: "习惯")
        case .task: return String(localized: "任务")
        case .goal: return String(localized: "目标")
        case .conversation: return String(localized: "对话")
        case .profile: return String(localized: "个人信息")
        }
    }
}

/// 预计算的领域分组。此前分组是计算属性，body 每次求值都对全量 records
/// 跑「9 组 × 全量过滤 + 每组求最新时间」，真机 2500+ 条记忆下滚动期
/// 主线程每帧数万次谓词调用；改为只在 records 变化时重建一次，body 只读。
private struct DomainMemoryGroupSection: Identifiable {
    let group: HoloMemoryDisplayGroup
    let records: [HoloMemoryRecord]
    let latestUpdatedAt: Date

    var id: String { group.rawValue }
}

struct DomainMemorySection: View {
    /// 拍平形态：内容直接作为外层 LazyVStack 的行（组头、每张记忆卡各自成行），
    /// 视口外不构建、滚出即回收——洞察页窄屏路径用它根治全量渲染卡顿。
    /// false = VStack 整体包装（宽屏双栏路径，布局语义与历史版本一致）。
    var flat: Bool = false
    /// 拍平形态下 section 头行与上一个区块的间距，由组装方（洞察页）按
    /// 上方是否有报告门卡传入，保持与原列布局等价的节奏。
    var headerTopSpacing: CGFloat = HoloSpacing.lg

    @ObservedObject private var memorySettings = HoloMemorySettings.shared
    @State private var records: [HoloMemoryRecord] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedRecord: HoloMemoryRecord?
    @State private var newMemoryIDs: Set<String> = []
    @State private var workingIDs: Set<String> = []
    @State private var notice: String?
    @State private var showsConfirmationQueue = false
    @State private var showsMemorySettings = false
    @State private var inboxSnapshot = HoloMemoryInboxSnapshot(
        newMemoryCount: 0,
        pendingConfirmationCount: 0,
        hasUnreadMigrationSummary: false
    )
    @State private var showsInboxSummary = false

    // MARK: - 分组缓存（records 变化时 rebuild，body 只读）

    @State private var pendingGroupRecords: [HoloMemoryRecord] = []
    @State private var domainGroups: [DomainMemoryGroupSection] = []
    @State private var observingGroupRecords: [HoloMemoryRecord] = []
    @State private var archivedGroupRecords: [HoloMemoryRecord] = []

    var body: some View {
        Group {
            if flat {
                flatContent
            } else {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    stackedContent
                }
            }
        }
        // 生命周期修饰符挂 section 主体而非任何具体行：拍平后行会随滚动被
        // LazyVStack 回收（sheet 锚随行消失=深区点卡弹层失效，实测教训），
        // section 自身的 @State 与 presentation 绑定不随行回收。
        .overlay(alignment: .top) {
            if let notice {
                MemoryNoticeToast(text: notice) { self.notice = nil }
            }
        }
        .task {
            // 拍平后行滚出视口会取消行级 task；section 级 task 不受影响。数据已在
            // 时短路（单条变更走 syncRecord 局部同步），只有首场与失败态才全量拉取。
            guard records.isEmpty || loadError != nil else { return }
            await load()
        }
        .sheet(isPresented: $showsMemorySettings) {
            NavigationStack {
                // 用户已在记忆长廊内：「进入记忆长廊」= 关掉设置 sheet 回长廊
                PersonalMemorySettingsView(onOpenMemoryGallery: { showsMemorySettings = false })
            }
        }
        .sheet(item: $selectedRecord) { record in
            NavigationStack {
                HoloMemoryRecordDetailView(record: record) { change in
                    apply(change)
                }
            }
        }
        .sheet(isPresented: $showsConfirmationQueue) {
            MemoryConfirmationQueueView(
                onRecordHandled: { id in
                    Task { await syncRecordByID(id) }
                },
                onQueueDrained: {
                    Task {
                        inboxSnapshot = await HoloMemoryReceiptStore.inboxSnapshot()
                        showsInboxSummary = !inboxSnapshot.isEmpty
                    }
                }
            )
        }
    }

    // MARK: - 拍平形态（LazyVStack 直行）

    /// 行级 padding 规则（与原 VStack 布局等距）：header 底 sm/2；普通块行
    /// 上 md−sm/2 下 sm/2（与 header 拼 md）；组头行上 md−sm/2 下 sm/2
    /// （与上一组末卡拼 md）；卡行上下各 sm/2（卡间拼 sm）。横向统一 md，
    /// 对应原列级 horizontal padding——拍平后不能在 section 外包 padding，
    /// 否则修饰符会把整棵树重新包成单个懒加载单元。
    private func flatRow<Content: View>(
        top: CGFloat = HoloSpacing.md - HoloSpacing.sm / 2,
        bottom: CGFloat = HoloSpacing.sm / 2,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, top)
            .padding(.bottom, bottom)
    }

    @ViewBuilder
    private var flatContent: some View {
        headerRow

        if !records.isEmpty, !memorySettings.memoryAssistedAnsweringEnabled {
            flatRow { answeringHintBar }
        }

        if showsInboxSummary, !inboxSnapshot.isEmpty {
            flatRow { inboxSummaryCard }
        }

        if isLoading {
            flatRow { loadingCard }
        } else if let loadError {
            flatRow { failureCard(loadError) }
        } else if records.isEmpty {
            flatRow { emptyCard }
        } else {
            if !pendingGroupRecords.isEmpty {
                // 回滚口径（收件箱开关关闭）保留旧「想和你确认的」任务组。
                pendingGroupHeader
                ForEach(pendingGroupRecords) { record in
                    flatRow(top: HoloSpacing.sm / 2) {
                        memoryCard(record, showsQuickConfirm: true, showsSourceInMetadata: true)
                    }
                }
            }
            // 「Holo 会参考」：领域分组里的可用内容（明确记忆 + 会谨慎参考的限定观察）。
            ForEach(domainGroups) { section in
                domainGroupHeader(section)
                ForEach(section.records) { record in
                    flatRow(top: HoloSpacing.sm / 2) {
                        memoryCard(record)
                    }
                }
            }
            if !observingGroupRecords.isEmpty {
                observingSection
            }
            if !archivedGroupRecords.isEmpty {
                archivedGroupHeader
                ForEach(archivedGroupRecords) { record in
                    flatRow(top: HoloSpacing.sm / 2) {
                        memoryCard(record, showsSourceInMetadata: true)
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        header
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, headerTopSpacing)
            .padding(.bottom, HoloSpacing.sm / 2)
    }

    // MARK: - 组头（拍平形态的独立行；堆叠形态并入组 VStack）

    private var pendingGroupHeader: some View {
        flatRow {
            groupHeaderRow(
                title: String(localized: "想和你确认的"),
                icon: "questionmark.bubble",
                count: pendingGroupRecords.count,
                subtitle: String(localized: "Holo 不太有把握的总结，确认后才会用于回答"),
                actionTitle: pendingGroupRecords.count > 3 ? String(localized: "逐条过一遍") : nil,
                action: { showsConfirmationQueue = true }
            )
        }
    }

    private var archivedGroupHeader: some View {
        flatRow {
            groupHeaderRow(
                title: String(localized: "过去记忆"),
                icon: "archivebox",
                count: archivedGroupRecords.count
            )
        }
    }

    private func domainGroupHeader(_ section: DomainMemoryGroupSection) -> some View {
        flatRow {
            groupHeaderRow(
                title: section.group.title,
                icon: section.group.icon,
                count: section.records.count,
                latest: section.latestUpdatedAt
            )
        }
    }

    // MARK: - 堆叠形态（宽屏双栏；行结构沿用历史版本）

    @ViewBuilder
    private var stackedContent: some View {
        header

        if !records.isEmpty, !memorySettings.memoryAssistedAnsweringEnabled {
            answeringHintBar
        }

        if showsInboxSummary, !inboxSnapshot.isEmpty {
            inboxSummaryCard
        }

        if isLoading {
            loadingCard
        } else if let loadError {
            failureCard(loadError)
        } else if records.isEmpty {
            emptyCard
        } else {
            if !pendingGroupRecords.isEmpty {
                specialMemoryGroup(
                    title: String(localized: "想和你确认的"),
                    icon: "questionmark.bubble",
                    records: pendingGroupRecords,
                    subtitle: String(localized: "Holo 不太有把握的总结，确认后才会用于回答"),
                    actionTitle: pendingGroupRecords.count > 3 ? String(localized: "逐条过一遍") : nil,
                    action: { showsConfirmationQueue = true },
                    showsQuickConfirm: true
                )
            }
            ForEach(domainGroups) { section in
                memoryGroup(section)
            }
            if !observingGroupRecords.isEmpty {
                observingSection
            }
            if !archivedGroupRecords.isEmpty {
                specialMemoryGroup(
                    title: String(localized: "过去记忆"),
                    icon: "archivebox",
                    records: archivedGroupRecords
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.holoPrimary)

                Text("Holo 的观察与记忆")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
            }

            Text("近期观察会随数据变化淡出；健康类记忆仅存本机、不同步 iCloud。")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    /// 「记忆辅助回答」关闭时的引导：萃取与展示不依赖该开关，但 AI 回答读取记忆
    /// 全靠它——不提示的话用户只会看到「记了一堆但没被用上」（2026-10-03 体检结论）。
    private var answeringHintBar: some View {
        Button {
            showsMemorySettings = true
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Holo 还没在回答中使用这些记忆")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                    Text("开启「记忆辅助回答」，HoloAI 才会读取它们")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextSecondary.opacity(0.5))
            }
            .padding(HoloSpacing.md)
            .background(Color.holoPrimary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(.plain)
    }

    /// 分组语义与历史计算属性 1:1（「Holo 会参考」= factEligible + qualifiedAdvice；
    /// 收件箱下线后 observe 类 candidate 移入「观察中」折叠组，不混入领域分组 §8.3）。
    /// 组顺序按「组内最新一条记忆的更新时间」倒序：最新变化的领域排最前，
    /// 时间并列时显式回退枚举声明顺序（Swift sort 不保证稳定）。
    private func rebuildGroupedRecords() {
        let current = records.filter { record in
            record.state != .candidate && record.state != .archived
        }
        domainGroups = HoloMemoryDisplayGroup.allCases
            .compactMap { group -> DomainMemoryGroupSection? in
                let groupRecords = current.filter { HoloMemoryDisplayGroup.group(for: $0) == group }
                guard !groupRecords.isEmpty else { return nil }
                return DomainMemoryGroupSection(
                    group: group,
                    records: groupRecords,
                    latestUpdatedAt: groupRecords.map(\.updatedAt).max() ?? .distantPast
                )
            }
            .enumerated()
            .sorted { lhs, rhs in
                let l = lhs.element.latestUpdatedAt, r = rhs.element.latestUpdatedAt
                return l == r ? lhs.offset < rhs.offset : l > r
            }
            .map(\.element)

        pendingGroupRecords = records.filter { HoloMemoryAttentionPolicy.requiresDailyConfirmation($0) }
        archivedGroupRecords = records.filter { $0.state == .archived }

        guard HoloMemoryAttentionPolicy.isDailyConfirmationInboxDisabled else {
            observingGroupRecords = []
            return
        }
        observingGroupRecords = records.filter { record in
            guard record.state == .candidate,
                  ![.rejected, .markedIrrelevant, .forgotten].contains(record.userDecision) else {
                return false
            }
            return HoloMemoryUserVisibility.isVisible(record)
        }
    }

    /// 「观察中」折叠组：无计数徽章、无清空义务，用户可主动打开纠正（§8.3）。
    /// 卡片带「对/不对」快捷确认：点「对」即经既有反馈链路置 active，立即可用于回答
    /// ——这是观察中记忆唯一的手动升级出口（收件箱已下线，后台不会自动升级）。
    /// 拍平形态下 DisclosureGroup 自身作为 LazyVStack 的一行（展开内容默认折叠不构建）；
    /// 堆叠形态保持组级块。
    private var observingSection: some View {
        Group {
            if flat {
                DisclosureGroup(isExpanded: $showsObservingSection) {
                    VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                        ForEach(observingGroupRecords) { record in
                            memoryCard(record, showsQuickConfirm: true, showsSourceInMetadata: true)
                        }
                    }
                    .padding(.top, HoloSpacing.xs)
                } label: {
                    observingSectionLabel
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.top, HoloSpacing.md - HoloSpacing.sm / 2)
                .padding(.bottom, HoloSpacing.sm / 2)
                Text("点「对」即可让 Holo 在回答中使用；不确认就继续观察。")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.bottom, HoloSpacing.sm / 2)
            } else {
                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    DisclosureGroup(isExpanded: $showsObservingSection) {
                        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                            ForEach(observingGroupRecords) { record in
                                memoryCard(record, showsQuickConfirm: true, showsSourceInMetadata: true)
                            }
                        }
                        .padding(.top, HoloSpacing.xs)
                    } label: {
                        observingSectionLabel
                    }
                    Text("点「对」即可让 Holo 在回答中使用；不确认就继续观察。")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
    }
    @State private var showsObservingSection = false

    private var observingSectionLabel: some View {
        HStack(spacing: HoloSpacing.xs) {
            Image(systemName: "eye")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.holoTextSecondary)
            Text("观察中")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private func memoryGroup(_ section: DomainMemoryGroupSection) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            groupHeaderRow(
                title: section.group.title,
                icon: section.group.icon,
                count: section.records.count,
                latest: section.latestUpdatedAt
            )

            ForEach(section.records) { record in
                memoryCard(record)
            }
        }
    }

    /// 组头行：条数徽章 + 组内最新更新日期（时间倒序排列后这是「新的在上面」的
    /// 直接线索）。拍平与堆叠形态共用。
    private func groupHeaderRow(
        title: String,
        icon: String,
        count: Int,
        latest: Date? = nil,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                Text(title)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoPrimary)
                }
                Text(Self.groupMetaText(count: count, latest: latest ?? .distantPast))
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }
        }
    }

    /// 组头摘要：条数 + 组内最新一条的更新日期，排序改为时间倒序后这是「新的在上面」的直接线索。
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static func groupMetaText(count: Int, latest: Date) -> String {
        guard latest != .distantPast else { return String(localized: "\(count) 条") }
        return String(localized: "\(count) 条 · \(dayFormatter.string(from: latest))更新")
    }

    private func specialMemoryGroup(
        title: String,
        icon: String,
        records: [HoloMemoryRecord],
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        showsQuickConfirm: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            groupHeaderRow(
                title: title,
                icon: icon,
                count: records.count,
                subtitle: subtitle,
                actionTitle: actionTitle,
                action: action
            )

            ForEach(records) { record in
                memoryCard(record, showsQuickConfirm: showsQuickConfirm, showsSourceInMetadata: true)
            }
        }
    }

    private func memoryCard(
        _ record: HoloMemoryRecord,
        showsQuickConfirm: Bool = false,
        showsSourceInMetadata: Bool = false
    ) -> some View {
        let feedbackBadge = HoloMemoryFeedbackBadge(decision: record.userDecision)
        let metadata = HoloMemoryUserPresentation.condensedMetadata(
            for: record,
            includesSource: showsSourceInMetadata
        )

        // 外层用 onTapGesture 而不是 Button：卡片内嵌「对/不对」按钮，Button 套 Button 会让两个动作同时触发。
        return VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(record.displaySummary)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if (record.state == .candidate && !HoloMemoryAttentionPolicy.isDailyConfirmationInboxDisabled)
                || newMemoryIDs.contains(record.id)
                || record.state == .archived
                || feedbackBadge != nil {
                HStack(spacing: 4) {
                    if record.state == .candidate,
                       !HoloMemoryAttentionPolicy.isDailyConfirmationInboxDisabled {
                        compactStatusBadge(String(localized: "待确认"), icon: "questionmark", color: .orange)
                    } else if record.state == .candidate {
                        compactStatusBadge(String(localized: "观察中"), icon: "eye", color: .holoTextSecondary)
                    } else if newMemoryIDs.contains(record.id) {
                        compactStatusBadge(String(localized: "新"), icon: "sparkles", color: .holoPrimary)
                    } else if record.state == .archived {
                        compactStatusBadge(String(localized: "过去"), icon: "archivebox", color: .holoTextSecondary)
                    }
                    if Self.isQualifiedAdvice(record) {
                        compactStatusBadge(String(localized: "会谨慎参考"), icon: "sparkle.magnifyingglass", color: .holoPrimary)
                    }
                    if let badge = feedbackBadge {
                        HoloMemoryFeedbackBadgeView(badge: badge)
                    }
                }
            }

            HStack(alignment: .top, spacing: HoloSpacing.xs) {
                if let metadata {
                    Text(metadata)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.holoTinyLabel)
            .foregroundColor(.holoTextPlaceholder)

            if showsQuickConfirm {
                HStack(spacing: HoloSpacing.sm) {
                    quickConfirmButton(record, accurate: true)
                    quickConfirmButton(record, accurate: false)
                }
            }

            if let status = HoloMemoryUserPresentation.degradedStatus(for: record) {
                Label(status, systemImage: "exclamationmark.circle")
                    .font(.holoTinyLabel)
                    .foregroundColor(.orange)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.45), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .onTapGesture { selectedRecord = record }
        .opacity(workingIDs.contains(record.id) ? 0.55 : 1)
        .disabled(workingIDs.contains(record.id))
    }

    private func quickConfirmButton(_ record: HoloMemoryRecord, accurate: Bool) -> some View {
        Button {
            Task { await quickConfirm(record, accurate: accurate) }
        } label: {
            Label(accurate ? String(localized: "对") : String(localized: "不对"), systemImage: accurate ? "checkmark" : "xmark")
                .font(.holoCaption)
                .foregroundColor(accurate ? .holoSuccess : .orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.sm)
                .background((accurate ? Color.holoSuccess : Color.orange).opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        }
        .buttonStyle(.plain)
    }

    private func compactStatusBadge(
        _ title: String,
        icon: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
            .fixedSize()
    }

    private var inboxSubtitle: String {
        if inboxSnapshot.pendingConfirmationCount > 0 {
            return String(localized: "确认后 Holo 回答会更准，几十秒就能清完")
        }
        return String(localized: "Holo 回答时会自动用上这些记忆，下方可随时管理")
    }

    private var inboxSummaryCard: some View {
        HStack(spacing: HoloSpacing.sm) {
            if inboxSnapshot.pendingConfirmationCount > 0 {
                Button {
                    showsConfirmationQueue = true
                } label: {
                    inboxLabelContent
                }
                .buttonStyle(.plain)
            } else {
                inboxLabelContent
            }

            Button {
                HoloMemoryReceiptStore.markWriteReceiptsRead()
                showsInboxSummary = false
                newMemoryIDs = []
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var inboxLabelContent: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "sparkles")
                .foregroundColor(.holoPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(inboxSnapshot.summaryText)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
                Text(inboxSubtitle)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if inboxSnapshot.pendingConfirmationCount > 0 {
                HStack(spacing: 2) {
                    Text("去确认")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.holoTinyLabel)
                .fontWeight(.semibold)
                .foregroundColor(.holoPrimary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var loadingCard: some View {
        HStack(spacing: HoloSpacing.sm) {
            ProgressView()
            Text("正在整理已经形成的记忆…")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private var emptyCard: some View {
        Text("还没有形成稳定记忆。继续使用 Holo 后，这里会逐步出现真正有帮助的总结。")
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Label("记忆暂时没有完整加载", systemImage: "exclamationmark.triangle")
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
            Text(message)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
            Button("重新加载") { Task { await load() } }
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            let unread = HoloMemoryReceiptStore.unreadWriteReceipts()
            newMemoryIDs = Set(unread.filter {
                $0.adoptionKind == .automaticallyAdopted
            }.flatMap(\.memoryIDs))
            inboxSnapshot = await HoloMemoryReceiptStore.inboxSnapshot()
            showsInboxSummary = !inboxSnapshot.isEmpty
            records = try await repository.query(.all).filter(Self.isUserVisible)
            rebuildGroupedRecords()
            isLoading = false
            #if DEBUG
            if HoloAppStoreScreenshotSeeder.requestedRoute == .memoryExtraction,
               !pendingGroupRecords.isEmpty {
                showsConfirmationQueue = true
            }
            #endif
        } catch {
            records = []
            rebuildGroupedRecords()
            loadError = String(localized: "你原来的记录没有丢失，可以稍后重试。")
            isLoading = false
        }
    }

    private static func isUserVisible(_ record: HoloMemoryRecord) -> Bool {
        HoloMemoryUserVisibility.isVisible(record)
    }

    /// 限定建议记忆：会影响回答但必须「可能相关/从记录看」限定表达（§8.3 标记，
    /// 与明确记忆区分；无决策元数据的旧记录按明确记忆展示）。
    private static func isQualifiedAdvice(_ record: HoloMemoryRecord) -> Bool {
        record.decisionMetadata?.v2?.useLevel == .qualifiedAdvice
    }

    private func apply(_ change: HoloMemoryRecordDetailChange) {
        switch change {
        case .updated(let record):
            syncRecord(record)
            selectedRecord = record
        case .removed(let id):
            newMemoryIDs.remove(id)
            withAnimation(HoloAnimation.smooth) {
                records.removeAll { $0.id == id }
            }
            rebuildGroupedRecords()
            selectedRecord = nil
        }
    }

    @MainActor
    private func quickConfirm(_ record: HoloMemoryRecord, accurate: Bool) async {
        workingIDs.insert(record.id)
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            let service = HoloMemoryFeedbackService(store: repository)
            _ = try await service.apply(accurate ? .accurate : .inaccurate, to: record.id)
            if let persisted = try await repository.fetch(id: record.id) {
                syncRecord(persisted)
            } else {
                newMemoryIDs.remove(record.id)
                withAnimation(HoloAnimation.smooth) {
                    records.removeAll { $0.id == record.id }
                }
                rebuildGroupedRecords()
            }
            refreshInboxSnapshot()
        } catch {
            notice = String(localized: "这次操作没有保存成功，请稍后重试。")
        }
        workingIDs.remove(record.id)
    }

    /// 确认队列里处理完一条后，按最新持久化状态同步本列表。
    @MainActor
    private func syncRecordByID(_ id: String) async {
        guard let repository = try? await HoloMemoryRuntime.shared.repository() else { return }
        if let persisted = try? await repository.fetch(id: id) {
            syncRecord(persisted)
        } else {
            newMemoryIDs.remove(id)
            withAnimation(HoloAnimation.smooth) {
                records.removeAll { $0.id == id }
            }
            rebuildGroupedRecords()
        }
        refreshInboxSnapshot()
    }

    private func syncRecord(_ record: HoloMemoryRecord) {
        newMemoryIDs.remove(record.id)
        withAnimation(HoloAnimation.smooth) {
            if Self.isUserVisible(record), let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.removeAll { $0.id == record.id }
            }
        }
        rebuildGroupedRecords()
    }

    private func refreshInboxSnapshot() {
        Task {
            inboxSnapshot = await HoloMemoryReceiptStore.inboxSnapshot()
            showsInboxSummary = !inboxSnapshot.isEmpty
        }
    }
}

enum HoloMemoryFeedbackBadge: Equatable {
    case accurate
    case inaccurate
    case corrected

    init?(decision: HoloMemoryUserDecision) {
        switch decision {
        case .confirmed: self = .accurate
        case .rejected: self = .inaccurate
        case .corrected: self = .corrected
        case .none, .markedIrrelevant, .forgotten: return nil
        }
    }

    var title: String {
        switch self {
        case .accurate: return String(localized: "准确")
        case .inaccurate: return String(localized: "不准确")
        case .corrected: return String(localized: "已纠正")
        }
    }

    var icon: String {
        switch self {
        case .accurate: return "checkmark"
        case .inaccurate: return "xmark"
        case .corrected: return "pencil"
        }
    }

    var color: Color {
        switch self {
        case .accurate: return .holoSuccess
        case .inaccurate: return .orange
        case .corrected: return .holoPrimary
        }
    }
}

struct HoloMemoryFeedbackBadgeView: View {
    let badge: HoloMemoryFeedbackBadge

    var body: some View {
        Label(badge.title, systemImage: badge.icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(badge.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(badge.color.opacity(0.1))
            .clipShape(Capsule())
            .fixedSize()
    }
}

enum HoloMemoryUserPresentation {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    static func durationTitle(for record: HoloMemoryRecord) -> String {
        switch record.persistenceClass {
        case .currentState: return String(localized: "近期观察")
        case .phase: return String(localized: "当前阶段")
        case .durable: return String(localized: "长期规律")
        case .permanentFact: return String(localized: "长期事实")
        }
    }

    static func durationIcon(for record: HoloMemoryRecord) -> String {
        switch record.persistenceClass {
        case .currentState: return "clock"
        case .phase: return "calendar"
        case .durable: return "repeat"
        case .permanentFact: return "bookmark.fill"
        }
    }

    static func durationExplanation(for record: HoloMemoryRecord) -> String {
        switch record.persistenceClass {
        case .currentState:
            return String(localized: "只代表最近一段时间，后续记录变化后会较快淡出。")
        case .phase:
            return String(localized: "代表你当前阶段的状态，通常会保留数周到数月。")
        case .durable:
            return String(localized: "由多个周期重复支持，会在相关问题中长期作为背景。")
        case .permanentFact:
            return String(localized: "这是明确的重要事实；除非你纠正或删除，否则会长期保留。")
        }
    }

    static func timeRange(for record: HoloMemoryRecord) -> String {
        // 每张记忆卡 body 都会调用，formatter 必须缓存（创建是 Foundation 重操作）
        let formatter = dayFormatter
        switch (record.validFrom, record.validTo) {
        case let (start?, end?):
            if Calendar.current.isDate(start, inSameDayAs: end) {
                return formatter.string(from: end)
            }
            return String(localized: "\(formatter.string(from: start))–\(formatter.string(from: end))")
        case let (start?, nil):
            return String(localized: "从\(formatter.string(from: start))起")
        case let (nil, end?):
            return String(localized: "截至\(formatter.string(from: end))")
        case (nil, nil):
            return String(localized: "持续观察中")
        }
    }

    static func sourceSummary(for record: HoloMemoryRecord) -> String {
        let names = record.sourceDomains.map(\.userFacingName)
        if record.scope == .crossDomain {
            return String(localized: "来自\(joined(names))的综合观察")
        }
        return String(localized: "来自\(joined(names))记录")
    }

    /// 列表卡的精简元信息：只在有实际日期或需要来源线索（观察中/确认/归档组
    /// 无分组标题可依）时返回内容，nil=整行不渲染。「长期规律」「持续观察中」等
    /// 恒定标签与完整解释移入详情页，避免整列卡片重复同一行字（2026-10-03 瘦身）。
    static func condensedMetadata(
        for record: HoloMemoryRecord,
        includesSource: Bool
    ) -> String? {
        var parts: [String] = []
        if includesSource {
            parts.append(sourceSummary(for: record))
        }
        if record.validFrom != nil || record.validTo != nil {
            parts.append(timeRange(for: record))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func degradedStatus(for record: HoloMemoryRecord) -> String? {
        if record.state == .candidate {
            // 收件箱下线后 candidate 不再是「等你确认的任务」，改为观察语义（P5 定稿文案）。
            if HoloMemoryAttentionPolicy.isDailyConfirmationInboxDisabled {
                return String(localized: "这条还在观察中，暂不会用于回答")
            }
            return String(localized: "确认后才会用于 HoloAI 回答")
        }
        if record.state == .archived {
            return String(localized: "这条记忆已经成为过去，不再用于当前回答")
        }
        if record.state == .invalidated {
            return String(localized: "来源已经变化，这条记忆已暂停使用")
        }
        if record.state == .disputed {
            return String(localized: "新的记录与它不完全一致，Holo 正在重新确认")
        }
        if record.evidenceRefs.isEmpty {
            return String(localized: "来源暂不可用，这条记忆不会用于回答")
        }
        if record.scope == .crossDomain && record.upstreamMemoryIDs.count < record.sourceDomains.count {
            return String(localized: "部分来源暂不可用，结论仅供参考")
        }
        return nil
    }

    private static func joined(_ values: [String]) -> String {
        let unique = Array(Set(values)).sorted()
        if unique.isEmpty { return String(localized: "你的") }
        if unique.count == 1 { return unique[0] }
        return unique.dropLast().joined(separator: String(localized: "、")) + String(localized: "和") + unique.last!
    }
}
