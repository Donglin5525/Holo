//
//  FinanceProjectListView.swift
//  Holo
//
//  财务项目列表——账户页「账户 | 项目」切换中项目侧的内容视图。
//  嵌入 AccountListView 的 NavigationStack（自带头卡/分区/空态，不含返回与工具栏）。
//  汇总卡（进行中 N 个/合计已花/合计预算）+ 进行中/已完结/已归档分区 + 行卡（图标/进度/已花）
//

import SwiftUI

/// 项目列表行数据（金额在父视图统一取数，避免行内反复查询）
struct FinanceProjectRowItem: Identifiable {
    let project: FinanceProject
    let totalExpense: Decimal

    var id: UUID { project.id }

    /// 预算进度 0...1（无预算或预算≤0 返回 nil）
    var budgetProgress: Double? {
        guard let budget = project.budgetDecimal, budget > 0 else { return nil }
        return min(max(NSDecimalNumber(decimal: totalExpense / budget).doubleValue, 0), 1)
    }

    var isOverBudget: Bool {
        guard let budget = project.budgetDecimal, budget > 0 else { return false }
        return totalExpense > budget
    }
}

struct FinanceProjectListView: View {

    /// 新建入口由父视图工具栏「+」触发
    @Binding var showAddProject: Bool

    @State private var activeItems: [FinanceProjectRowItem] = []
    @State private var completedItems: [FinanceProjectRowItem] = []
    @State private var archivedItems: [FinanceProjectRowItem] = []
    @State private var summary = FinanceProjectRepository.Summary()

    @State private var editingProject: FinanceProject?
    @State private var detailProject: FinanceProject?
    @State private var showDetail = false
    @State private var showArchived = false

    var body: some View {
        VStack(spacing: HoloSpacing.md) {
            if activeItems.isEmpty && completedItems.isEmpty && archivedItems.isEmpty {
                emptyStateView
            } else {
                summaryCard
                activeSection
                completedSection
                archivedSection
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            if let project = detailProject {
                FinanceProjectDetailView(project: project)
            }
        }
        .sheet(item: $editingProject) { project in
            AddProjectSheet(mode: .edit(project)) { loadData() }
        }
        .onAppear { loadData() }
        .onChange(of: showAddProject) { _, showing in
            if !showing { loadData() }
        }
        // 惰性删除发生在详情页 onDisappear（可能晚于本列表 onAppear），
        // 靠数据变更通知兜住刷新，避免列表残留已删项目行
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            loadData()
        }
    }

    // MARK: - 汇总卡

    private var summaryCard: some View {
        VStack(spacing: HoloSpacing.md) {
            HStack {
                Text("进行中 · \(summary.activeCount) 个项目")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.1)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                if summary.totalBudget > 0 {
                    Text("预算 \(formatAmount(summary.totalBudget))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }

            Text(formatAmount(summary.totalExpense))
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)

            if summary.totalBudget > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.holoDivider.opacity(0.5))
                        Capsule()
                            .fill(overallProgressColor)
                            .frame(width: proxy.size.width * overallProgress)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(16)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .strokeBorder(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var overallProgress: CGFloat {
        guard summary.totalBudget > 0 else { return 0 }
        let ratio = NSDecimalNumber(decimal: summary.totalExpense / summary.totalBudget).doubleValue
        return min(max(CGFloat(ratio), 0), 1)
    }

    private var overallProgressColor: Color {
        progressColor(ratio: overallProgress)
    }

    /// 进度配色（与预算进度条同口径：<0.6 绿、≥0.8 品牌橙、≥1 红）
    private func progressColor(ratio: Double) -> Color {
        if ratio >= 1 { return .holoError }
        if ratio >= 0.8 { return .holoPrimary }
        return .holoSuccess
    }

    // MARK: - 分区

    @ViewBuilder
    private var activeSection: some View {
        if !activeItems.isEmpty {
            VStack(spacing: 0) {
                ForEach(activeItems) { item in
                    projectRow(item: item)
                    if item.id != activeItems.last?.id {
                        Divider()
                            .background(Color.holoDivider.opacity(0.55))
                            .padding(.leading, 68)
                    }
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .strokeBorder(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private var completedSection: some View {
        if !completedItems.isEmpty {
            VStack(spacing: 0) {
                sectionHeader("已完结 · \(completedItems.count) 个")
                ForEach(completedItems) { item in
                    projectRow(item: item)
                    if item.id != completedItems.last?.id {
                        Divider()
                            .background(Color.holoDivider.opacity(0.55))
                            .padding(.leading, 68)
                    }
                }
            }
            .background(Color.holoCardBackground.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .strokeBorder(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private var archivedSection: some View {
        if !archivedItems.isEmpty {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showArchived.toggle() }
                } label: {
                    HStack {
                        Text("已归档 · \(archivedItems.count) 个")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                        Spacer()
                        Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showArchived {
                    ForEach(archivedItems) { item in
                        projectRow(item: item)
                    }
                }
            }
            .background(Color.holoCardBackground.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .strokeBorder(Color.holoDivider.opacity(0.4), lineWidth: 0.5)
            )
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    // MARK: - 项目行

    private func projectRow(item: FinanceProjectRowItem) -> some View {
        let tint = Color(hex: item.project.color)
        let status = item.project.statusEnum
        return Button {
            detailProject = item.project
            showDetail = true
        } label: {
            HStack(spacing: 12) {
                Text(item.project.icon)
                    .font(.system(size: 20))
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.project.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                        if status == .completed {
                            statusCapsule("已完结")
                        } else if status == .archived {
                            statusCapsule("已归档")
                        }
                    }
                    if let range = Self.dateRangeLabel(for: item.project) {
                        Text(range)
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
                    }
                    if let progress = item.budgetProgress {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.holoDivider.opacity(0.5))
                                Capsule()
                                    .fill(progressColor(ratio: progress))
                                    .frame(width: proxy.size.width * CGFloat(progress))
                            }
                        }
                        .frame(height: 3)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("¥\(AccountCardFormat.amount(item.totalExpense))")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(item.isOverBudget ? .holoError : .holoTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let budget = item.project.budgetDecimal, budget > 0 {
                        Text("预算 \(AccountCardFormat.amount(budget))")
                            .font(.system(size: 9.5))
                            .foregroundColor(.holoTextSecondary)
                    } else {
                        Text("已花")
                            .font(.system(size: 9.5))
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project.row.\(item.project.name)")
        .contextMenu {
            Button { editingProject = item.project } label: {
                Label("编辑项目", systemImage: "pencil")
            }
        }
    }

    private func statusCapsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(.holoTextSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.holoGlassBackground))
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("还没有项目")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text("把多笔支出归到一件事上，比如旅行、装修")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary.opacity(0.8))

            Button {
                showAddProject = true
            } label: {
                Text("新建第一个项目")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.holoPrimary))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - 数据

    private func loadData() {
        let repo = FinanceProjectRepository.shared
        let all = repo.allProjects()
        func row(_ project: FinanceProject) -> FinanceProjectRowItem {
            FinanceProjectRowItem(project: project, totalExpense: repo.totalExpense(forProject: project.id))
        }
        activeItems = all.filter { $0.statusEnum == .active }.map(row)
        completedItems = all.filter { $0.statusEnum == .completed }.map(row)
        archivedItems = all.filter { $0.statusEnum == .archived }.map(row)
        summary = repo.summary()
    }

    private func formatAmount(_ amount: Decimal) -> String {
        "¥\(AccountCardFormat.amount(amount))"
    }

    /// 时间范围展示文案（静态 formatter，避免行内反复创建）
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func dateRangeLabel(for project: FinanceProject) -> String? {
        switch (project.startDate, project.endDate) {
        case let (start?, end?):
            return "\(dayFormatter.string(from: start)) – \(dayFormatter.string(from: end))"
        case let (start?, nil):
            return "\(dayFormatter.string(from: start)) 起"
        case let (nil, end?):
            return "至 \(dayFormatter.string(from: end))"
        default:
            return nil
        }
    }
}
