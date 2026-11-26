//
//  SpendingProjectsView.swift
//  Holo
//
//  固定支出 —— 财务模块底部第 4 个 Tab
//  页内双分段：「订阅与周期」（含即将到期 / 订阅中 / 分期中 / 已停订）与「大件持有」
//  遵循 Holo 2026-11-24 反 AI 味高审美规范：默认无卡落纸底、衬线主角大数字、一页一橙。
//

import SwiftUI
import CoreData

struct SpendingProjectsView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case recurring
        case asset

        var id: String { rawValue }
        var title: String {
            switch self {
            case .recurring: String(localized: "订阅与周期")
            case .asset: String(localized: "大件持有")
            }
        }
    }

    let onBack: () -> Void

    @State private var selectedSegment: Segment = .recurring
    @State private var projects: [SpendingProject] = []
    @State private var showAdd = false
    @State private var showPausedList = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("固定支出分类", selection: $selectedSegment) {
                        ForEach(Segment.allCases) { seg in
                            Text(seg.title).tag(seg)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, HoloSpacing.md)

                    if selectedSegment == .recurring {
                        recurringContent
                    } else {
                        assetContent
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.sm)
                // 底部避让：财务底栏实测高 122pt，保证最后一行可完整滚出
                .padding(.bottom, 120)
            }
            .background(Color.holoToolBackground)
            .navigationTitle("固定支出")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.holoToolBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .holoIconSize(.md, weight: .semibold)
                            .foregroundStyle(Color.holoToolText)
                    }
                }
                ToolbarItem(placement: HoloToolbarPlacement.topBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                            .holoIconSize(.md, weight: .medium)
                            .foregroundStyle(Color.holoToolText)
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddSpendingProjectSheet(
                    initialMode: selectedSegment == .asset ? .asset : .subscription
                ) {
                    reloadListOnly()
                }
            }
            .task { syncAndReload() }
            .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in reloadListOnly() }
            .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in reloadListOnly() }
        }
    }

    // MARK: - 订阅与周期视图

    private var activeRecurring: [SpendingProject] {
        projects.renderable
            .filter { $0.isRecurring && !$0.isPaused && $0.hasRemainingOccurrences }
            .sorted { lhs, rhs in
                let lDate = lhs.nextOccurrenceDate ?? .distantFuture
                let rDate = rhs.nextOccurrenceDate ?? .distantFuture
                return lDate < rDate
            }
    }

    private var dueSoonProjects: [SpendingProject] {
        activeRecurring.filter {
            guard let days = $0.daysUntilNextOccurrence() else { return false }
            return days >= 0 && days <= 7
        }
    }

    private var regularSubscriptions: [SpendingProject] {
        let dueSoonIDs = Set(dueSoonProjects.map(\.objectID))
        return activeRecurring.filter { !$0.isInstallment && !dueSoonIDs.contains($0.objectID) }
    }

    private var activeInstallments: [SpendingProject] {
        let dueSoonIDs = Set(dueSoonProjects.map(\.objectID))
        return activeRecurring.filter { $0.isInstallment && !dueSoonIDs.contains($0.objectID) }
    }

    private var inactiveRecurring: [SpendingProject] {
        projects.renderable.filter { $0.isRecurring && ($0.isPaused || !$0.hasRemainingOccurrences) }
    }

    @ViewBuilder
    private var recurringContent: some View {
        if activeRecurring.isEmpty && inactiveRecurring.isEmpty {
            emptyPlaceholder(
                quote: String(localized: "还没有记录任何订阅"),
                subtitle: String(localized: "把会员、软件订阅或定期账单放进来，看清每月固定流出，到期前从容决定续与停。"),
                buttonTitle: String(localized: "添加第一条订阅")
            )
        } else {
            recurringHeroSummary

            if !dueSoonProjects.isEmpty {
                recurringGroup(
                    title: "即将到期",
                    trailing: String(localized: "7 天内"),
                    items: dueSoonProjects
                )
            }

            if !regularSubscriptions.isEmpty {
                let subMonthly = regularSubscriptions.compactMap(\.monthlyCommitment).reduce(Decimal(0), +)
                recurringGroup(
                    title: "订阅中",
                    trailing: String(localized: "月均 \(NumberFormatter.currencyTrimmed.string(from: subMonthly as NSDecimalNumber) ?? "¥0")"),
                    items: regularSubscriptions
                )
            }

            if !activeInstallments.isEmpty {
                recurringGroup(
                    title: "分期中",
                    trailing: String(localized: "\(activeInstallments.count) 项"),
                    items: activeInstallments
                )
            }

            if !inactiveRecurring.isEmpty {
                inactiveSection
            }
        }
    }

    private var recurringHeroSummary: some View {
        let monthlyTotal = activeRecurring.compactMap(\.monthlyCommitment).reduce(Decimal(0), +)
        let yearlyTotal = monthlyTotal * 12
        let subCount = activeRecurring.filter { !$0.isInstallment }.count
        let instCount = activeRecurring.filter(\.isInstallment).count
        let dueSoonSum = dueSoonProjects.map(\.amountDecimal).reduce(Decimal(0), +)

        return VStack(alignment: .leading, spacing: 0) {
            Text(instCount > 0 ? String(localized: "每月固定承诺") : String(localized: "每月订阅承诺"))
                .font(.holoLabel)
                .foregroundStyle(Color.holoToolTextSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(NumberFormatter.currency.string(from: monthlyTotal as NSDecimalNumber) ?? "¥0")
                    .font(.holoHeroNumber(size: 34))
                    .foregroundStyle(Color.holoToolText)
                    .monospacedDigit()
                Text("/ 月")
                    .font(.holoCaption)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .padding(.top, 4)

            HStack(spacing: 12) {
                metaStat(label: String(localized: "年化"), value: NumberFormatter.currencyTrimmed.string(from: yearlyTotal as NSDecimalNumber) ?? "¥0")
                metaSeparator
                metaStat(label: String(localized: "订阅"), value: String(localized: "\(subCount) 项"))
                if instCount > 0 {
                    metaSeparator
                    metaStat(label: String(localized: "分期"), value: String(localized: "\(instCount) 项"))
                }
            }
            .padding(.top, 10)

            if !dueSoonProjects.isEmpty {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.holoToolAction)
                        .frame(width: 6, height: 6)
                    Text(String(localized: "7 天内有 \(dueSoonProjects.count) 笔即将到期 · 合计 \(NumberFormatter.currencyTrimmed.string(from: dueSoonSum as NSDecimalNumber) ?? "¥0")"))
                        .font(.holoLabel)
                        .foregroundStyle(Color.holoToolAction)
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.holoToolAction.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous))
                .padding(.top, 14)
            }
        }
        .padding(.bottom, HoloSpacing.md)
        .overlay(alignment: .bottom) { HoloHairlineDivider() }
    }

    private func recurringGroup(title: LocalizedStringKey, trailing: String, items: [SpendingProject]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HoloSectionHeader(title) {
                HoloSectionDetailLabel(text: trailing)
            }
            .padding(.top, HoloSpacing.lg)
            .padding(.bottom, HoloSpacing.xs)

            ForEach(items.renderable, id: \.objectID) { project in
                NavigationLink {
                    SpendingProjectDetailView(project: project) { reloadListOnly() }
                } label: {
                    recurringRow(project)
                }
                .buttonStyle(.plain)
                if project.objectID != items.renderable.last?.objectID {
                    HoloHairlineDivider(leadingInset: 54)
                }
            }
        }
    }

    private func recurringRow(_ project: SpendingProject) -> some View {
        let days = project.daysUntilNextOccurrence()
        let isUrgent = days.map { $0 >= 0 && $0 <= 7 } ?? false

        return HStack(spacing: 12) {
            SpendingProjectIconSlot(project: project, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(project.name)
                        .font(.holoBody)
                        .foregroundStyle(Color.holoToolText)
                        .lineLimit(1)
                    if project.reminderEnabled && !project.isPaused {
                        Image(systemName: "bell")
                            .holoIconSize(.xs)
                            .foregroundStyle(isUrgent ? Color.holoToolAction : Color.holoToolTextSecondary)
                    }
                }

                Text(recurringSubtitle(project))
                    .font(.holoLabel)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1)

                if project.isInstallment, project.maxOccurrences > 0 {
                    let progress = Double(project.occurrencesGenerated) / Double(project.maxOccurrences)
                    HoloHairlineProgressTrack(progress: progress, tint: .holoToolTextSecondary, height: 2.5)
                        .frame(width: 110)
                        .padding(.top, 3)
                }
            }

            Spacer(minLength: HoloSpacing.sm)

            VStack(alignment: .trailing, spacing: 3) {
                Text(NumberFormatter.currencyTrimmed.string(from: project.amount) ?? "¥0")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.holoToolText)
                    .monospacedDigit()

                Text(dueTrailingText(project, days: days))
                    .font(.holoLabel)
                    .fontWeight(isUrgent ? .semibold : .regular)
                    .foregroundStyle(isUrgent ? Color.holoToolAction : Color.holoToolTextSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var inactiveSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(HoloAnimation.standard) { showPausedList.toggle() }
            } label: {
                HStack {
                    Text(String(localized: "已停订 / 已完成 · \(inactiveRecurring.count) 项"))
                        .font(.holoCaption)
                        .foregroundStyle(Color.holoToolTextSecondary)
                    Spacer()
                    Image(systemName: showPausedList ? "chevron.up" : "chevron.down")
                        .holoIconSize(.xs)
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, HoloSpacing.md)
            .overlay(alignment: .top) {
                HoloHairlineDivider()
                    .padding(.top, HoloSpacing.md)
            }

            if showPausedList {
                ForEach(inactiveRecurring.renderable, id: \.objectID) { project in
                    NavigationLink {
                        SpendingProjectDetailView(project: project) { reloadListOnly() }
                    } label: {
                        recurringRow(project)
                            .opacity(0.62)
                    }
                    .buttonStyle(.plain)
                    if project.objectID != inactiveRecurring.renderable.last?.objectID {
                        HoloHairlineDivider(leadingInset: 54)
                    }
                }
            }
        }
    }

    // MARK: - 大件持有视图

    private var assetProjects: [SpendingProject] {
        projects.renderable
            .filter { !$0.isRecurring }
            .sorted { ($0.dailyCost ?? 0) > ($1.dailyCost ?? 0) }
    }

    @ViewBuilder
    private var assetContent: some View {
        if assetProjects.isEmpty {
            emptyPlaceholder(
                quote: String(localized: "还没有记录大件物品"),
                subtitle: String(localized: "记录电脑、相机、座驾等一次性购置，随时间流逝看清每天的真实持有成本。"),
                buttonTitle: String(localized: "添加第一件物品")
            )
        } else {
            assetHeroSummary

            HoloSectionHeader("持有中") {
                HoloSectionDetailLabel(text: String(localized: "\(assetProjects.count) 件"))
            }
            .padding(.top, HoloSpacing.lg)
            .padding(.bottom, HoloSpacing.xs)

            ForEach(assetProjects.renderable, id: \.objectID) { project in
                NavigationLink {
                    SpendingProjectDetailView(project: project) { reloadListOnly() }
                } label: {
                    assetRow(project)
                }
                .buttonStyle(.plain)
                if project.objectID != assetProjects.renderable.last?.objectID {
                    HoloHairlineDivider(leadingInset: 54)
                }
            }
        }
    }

    private var assetHeroSummary: some View {
        let dailyTotal = assetProjects.compactMap(\.dailyCost).reduce(Decimal(0), +)
        let purchaseTotal = assetProjects.map(\.amountDecimal).reduce(Decimal(0), +)

        return VStack(alignment: .leading, spacing: 0) {
            Text("大件折合每日持有成本")
                .font(.holoLabel)
                .foregroundStyle(Color.holoToolTextSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(NumberFormatter.currency.string(from: dailyTotal as NSDecimalNumber) ?? "¥0")
                    .font(.holoHeroNumber(size: 34))
                    .foregroundStyle(Color.holoToolText)
                    .monospacedDigit()
                Text("/ 天")
                    .font(.holoCaption)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            .padding(.top, 4)

            HStack(spacing: 12) {
                metaStat(label: String(localized: "总购置"), value: NumberFormatter.currencyTrimmed.string(from: purchaseTotal as NSDecimalNumber) ?? "¥0")
                metaSeparator
                metaStat(label: String(localized: "在持"), value: String(localized: "\(assetProjects.count) 件"))
            }
            .padding(.top, 10)
        }
        .padding(.bottom, HoloSpacing.md)
        .overlay(alignment: .bottom) { HoloHairlineDivider() }
    }

    private func assetRow(_ project: SpendingProject) -> some View {
        HStack(spacing: 12) {
            SpendingProjectIconSlot(project: project, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.holoBody)
                    .foregroundStyle(Color.holoToolText)
                    .lineLimit(1)
                Text(String(localized: "已持有 \(project.ownershipElapsedDays) 天"))
                    .font(.holoLabel)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }

            Spacer(minLength: HoloSpacing.sm)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(NumberFormatter.currency.string(from: (project.dailyCost ?? 0) as NSDecimalNumber) ?? "¥0")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.holoToolText)
                        .monospacedDigit()
                    Text("/天")
                        .font(.holoTinyLabel)
                        .foregroundStyle(Color.holoToolTextSecondary)
                }
                Text(String(localized: "购入 \(NumberFormatter.currencyTrimmed.string(from: project.amount) ?? "¥0")"))
                    .font(.holoLabel)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func emptyPlaceholder(quote: String, subtitle: String, buttonTitle: String) -> some View {
        VStack(spacing: HoloSpacing.md) {
            Rectangle()
                .fill(Color.holoToolBorder)
                .frame(width: 36, height: 1)
                .padding(.top, 48)

            Text(quote)
                .font(.holoHeading)
                .foregroundStyle(Color.holoToolText)

            Text(subtitle)
                .font(.holoCaption)
                .foregroundStyle(Color.holoToolTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, HoloSpacing.md)

            Button {
                showAdd = true
            } label: {
                Text(buttonTitle)
            }
            .buttonStyle(.holoSecondary)
            .padding(.top, HoloSpacing.xs)
        }
        .frame(maxWidth: .infinity)
    }

    private func metaStat(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.holoLabel)
                .foregroundStyle(Color.holoToolTextSecondary)
            Text(value)
                .font(.holoLabel)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolText)
                .monospacedDigit()
        }
    }

    private var metaSeparator: some View {
        Rectangle()
            .fill(Color.holoToolBorder)
            .frame(width: 0.5, height: 10)
    }

    private func recurringSubtitle(_ project: SpendingProject) -> String {
        if project.isPaused { return String(localized: "已停订") }
        if !project.hasRemainingOccurrences { return String(localized: "已完成") }
        if project.isInstallment {
            return String(localized: "已还 \(project.occurrencesGenerated) / \(project.maxOccurrences) 期")
        }
        let freq = project.resolvedFrequency.title
        let mode = project.autoGenerateTransaction ? String(localized: "自动记账") : String(localized: "仅提醒")
        if project.resolvedFrequency != .monthly, let monthly = project.monthlyCommitment {
            return String(localized: "\(freq) · 折合 \(NumberFormatter.currencyTrimmed.string(from: monthly as NSDecimalNumber) ?? "¥0")/月")
        }
        return "\(freq) · \(mode)"
    }

    private func dueTrailingText(_ project: SpendingProject, days: Int?) -> String {
        if project.isPaused { return String(localized: "已停订") }
        if !project.hasRemainingOccurrences { return String(localized: "已完成") }
        if let days {
            if days == 0 { return String(localized: "今天到期") }
            if days == 1 { return String(localized: "明天到期") }
            if days > 1 && days <= 7 { return String(localized: "\(days) 天后到期") }
        }
        if let next = project.nextOccurrenceDate {
            return BillDueReminderScheduler.dueDateFormatter.string(from: next)
        }
        return ""
    }

    /// 首次进入页面时同步一次周期补账并拉取列表（绝不在 .financeDataDidChange 通知回调里调用，防止广播死循环）
    private func syncAndReload() {
        FinanceRepository.shared.migrateFixedExpenseSemantics()
        try? SpendingProjectRepository.shared.syncRecurringProjects()
        try? SpendingProjectRepository.shared.syncOneOffProjects()
        projects = SpendingProjectRepository.shared.allProjects()
    }

    /// 纯读刷新列表（供通知与子页面回调使用，零写入、零广播）
    private func reloadListOnly() {
        projects = SpendingProjectRepository.shared.allProjects()
    }
}
