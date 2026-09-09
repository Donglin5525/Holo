//
//  FinanceProjectDetailView.swift
//  Holo
//
//  财务项目详情页
//  头卡（总支出 + 笔数/日均三指标 + 预算进度）→ 分类构成（点击下钻筛选交易流）→ 交易流（按日分组）
//  菜单：编辑 / 添加交易（新记一笔预挂项目、从历史批量补挂）/ 完结 / 归档 / 删除（只解除关联，不删交易）
//

import SwiftUI
import CoreData

struct FinanceProjectDetailView: View {

    let project: FinanceProject

    @Environment(\.dismiss) private var dismiss

    @State private var totalExpense: Decimal = 0
    @State private var expenseCount: Int = 0
    @State private var categoryAggregations: [CategoryAggregation] = []
    @State private var transactions: [Transaction] = []

    @State private var editingProject = false
    @State private var editingTransaction: Transaction?
    @State private var showAddTransaction = false
    @State private var showHistoryPicker = false
    @State private var showDeleteConfirm = false
    /// 惰性删除（与 SpendingProjectDetailView 同款）：dismiss 动画期间 body 仍会读
    /// project 的属性，先删库会触发已删对象 fault 崩溃——先记 objectID，onDisappear 再真删
    @State private var pendingDeletionID: NSManagedObjectID?
    /// 分类下钻筛选（nil=显示全部；点击分类构成行切换）
    @State private var categoryFilter: Category?

    private var projectRepo: FinanceProjectRepository { .shared }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.md) {
                headerCard
                categorySection
                transactionSection
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.xs)
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 24)
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.holoBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button {
                            showAddTransaction = true
                        } label: {
                            Label("记一笔挂到项目", systemImage: "plus.circle")
                        }
                        Button {
                            showHistoryPicker = true
                        } label: {
                            Label("从历史挑一笔补挂", systemImage: "clock.arrow.circlepath")
                        }
                    }
                    Section {
                        Button { editingProject = true } label: {
                            Label("编辑项目", systemImage: "pencil")
                        }
                        .accessibilityIdentifier("projectDetail.edit")
                        if project.statusEnum == .active {
                            Button {
                                try? projectRepo.updateStatus(project, status: .completed)
                                loadData()
                            } label: {
                                Label("完结项目", systemImage: "checkmark.circle")
                            }
                        } else if project.statusEnum == .completed {
                            Button {
                                try? projectRepo.updateStatus(project, status: .active)
                                loadData()
                            } label: {
                                Label("重新开启", systemImage: "arrow.counterclockwise")
                            }
                        }
                        if project.statusEnum == .archived {
                            Button {
                                try? projectRepo.updateStatus(project, status: .active)
                                loadData()
                            } label: {
                                Label("取消归档", systemImage: "tray.and.arrow.up")
                            }
                        } else {
                            Button {
                                try? projectRepo.updateStatus(project, status: .archived)
                                dismiss()
                            } label: {
                                Label("归档项目", systemImage: "archivebox")
                            }
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("删除项目", systemImage: "trash")
                        }
                        .accessibilityIdentifier("projectDetail.delete")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                }
                .accessibilityLabel("项目操作菜单")
                .accessibilityIdentifier("projectDetail.menu")
            }
        }
        .sheet(isPresented: $editingProject) {
            AddProjectSheet(mode: .edit(project)) { loadData() }
        }
        .sheet(isPresented: $showAddTransaction) {
            AddTransactionSheet(editingTransaction: nil, presetFinanceProject: project) { _ in
                loadData()
            }
        }
        .sheet(isPresented: $showHistoryPicker) {
            ProjectHistoryPickerSheet(project: project) {
                loadData()
            }
        }
        .sheet(item: $editingTransaction) { tx in
            AddTransactionSheet(editingTransaction: tx) { _ in
                loadData()
            }
        }
        .confirmationDialog(
            "删除项目「\(project.name)」？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("只解除关联并删除项目", role: .destructive) {
                pendingDeletionID = project.objectID
                dismiss()
            }
            .accessibilityIdentifier("projectDetail.deleteConfirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("该项目下 \(transactions.count) 笔交易会保留，只是不再算进这个项目；项目本身可随时重新创建。")
        }
        .onDisappear { performPendingDeletion() }
        .onAppear { loadData() }
    }

    /// 页面完全消失后才执行删除（dismiss 动画期间对象必须还活着）
    private func performPendingDeletion() {
        guard let projectID = pendingDeletionID else { return }
        pendingDeletionID = nil
        guard let project = try? projectRepo.context.existingObject(with: projectID) as? FinanceProject else { return }
        try? projectRepo.deleteProject(project)
    }

    // MARK: - 头卡

    private var headerCard: some View {
        VStack(spacing: HoloSpacing.md) {
            HStack(spacing: 10) {
                Text(project.icon)
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .background(Color(hex: project.color).opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let range = FinanceProjectListView.dateRangeLabel(for: project) {
                            Text(range)
                                .font(.system(size: 11))
                                .foregroundColor(.holoTextSecondary)
                        }
                        if project.statusEnum == .completed {
                            statusCapsule("已完结")
                        } else if project.statusEnum == .archived {
                            statusCapsule("已归档")
                        }
                    }
                }
                Spacer()
            }

            Text("¥\(AccountCardFormat.amount(totalExpense))")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                metricItem("交易笔数", "\(expenseCount)")
                Divider().frame(height: 30)
                metricItem("日均", "¥\(AccountCardFormat.amount(dailyAverage))")
                Divider().frame(height: 30)
                metricItem("预算", project.budgetDecimal.map { "¥\(AccountCardFormat.amount($0))" } ?? "未设置")
            }

            if let budget = project.budgetDecimal, budget > 0 {
                budgetProgressBar(budget: budget)
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

    private func metricItem(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundColor(.holoTextSecondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func budgetProgressBar(budget: Decimal) -> some View {
        let ratio: Double = {
            guard budget > 0 else { return 0 }
            return min(max(NSDecimalNumber(decimal: totalExpense / budget).doubleValue, 0), 1)
        }()
        let remaining = budget - totalExpense
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.holoDivider.opacity(0.5))
                    Capsule()
                        .fill(progressColor(ratio: ratio))
                        .frame(width: proxy.size.width * CGFloat(ratio))
                }
            }
            .frame(height: 5)

            Text(ratio >= 1
                 ? "已超支 ¥\(AccountCardFormat.amount(-remaining))"
                 : "剩余 ¥\(AccountCardFormat.amount(remaining)) · \(Int((ratio * 100).rounded()))%")
                .font(.system(size: 11))
                .foregroundColor(ratio >= 1 ? .holoError : .holoTextSecondary)
        }
    }

    /// 进度配色（<0.6 绿、≥0.8 品牌橙、≥1 红）
    private func progressColor(ratio: Double) -> Color {
        if ratio >= 1 { return .holoError }
        if ratio >= 0.8 { return .holoPrimary }
        return .holoSuccess
    }

    private func statusCapsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(.holoTextSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.holoGlassBackground))
    }

    // MARK: - 分类构成

    @ViewBuilder
    private var categorySection: some View {
        if !categoryAggregations.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("分类构成")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                VStack(spacing: 0) {
                    ForEach(categoryAggregations, id: \.category.id) { aggregation in
                        categoryRow(aggregation)
                        if aggregation.category.id != categoryAggregations.last?.category.id {
                            Divider()
                                .background(Color.holoDivider.opacity(0.55))
                                .padding(.leading, 52)
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
    }

    private func categoryRow(_ aggregation: CategoryAggregation) -> some View {
        let isSelected = categoryFilter?.id == aggregation.category.id
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                categoryFilter = isSelected ? nil : aggregation.category
            }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    CategoryIconBadge(
                        iconName: aggregation.category.icon,
                        color: Color(hex: aggregation.category.color),
                        diameter: 32
                    )

                    Text(aggregation.category.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text("¥\(AccountCardFormat.amount(aggregation.amount))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.holoTextPrimary)
                    Text(String(format: "%.0f%%", aggregation.percentage))
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 34, alignment: .trailing)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.holoDivider.opacity(0.35))
                        Capsule()
                            .fill(Color(hex: aggregation.category.color).opacity(0.75))
                            .frame(width: proxy.size.width * CGFloat(min(aggregation.percentage / 100, 1)))
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 交易流

    private var visibleTransactions: [Transaction] {
        guard let filter = categoryFilter else { return transactions }
        return transactions.filter { tx in
            guard let category = tx.category else { return false }
            if category.id == filter.id { return true }
            // 二级分类交易归入其一级分类一起展示
            return category.parentId == filter.id
        }
    }

    private var transactionSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("交易记录 · \(visibleTransactions.count) 笔")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                if categoryFilter != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { categoryFilter = nil }
                    } label: {
                        HStack(spacing: 3) {
                            Text(categoryFilter?.name ?? "")
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.holoPrimary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            if visibleTransactions.isEmpty {
                VStack(spacing: HoloSpacing.md) {
                    Image(systemName: "receipt")
                        .font(.system(size: 32))
                        .foregroundColor(.holoTextSecondary)
                    Text("暂无交易记录")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                    Text("点右上角菜单，记一笔或从历史补挂")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .padding(HoloSpacing.xl)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            } else {
                let grouped = groupByDate(visibleTransactions)
                ForEach(grouped.keys.sorted(by: >), id: \.self) { date in
                    if let dayTransactions = grouped[date] {
                        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                            Text(Self.dateFormatter.string(from: date))
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                                .padding(.leading, HoloSpacing.sm)

                            ForEach(dayTransactions, id: \.objectID) { tx in
                                TransactionRowView(transaction: tx) {
                                    editingTransaction = tx
                                }
                                .contextMenu {
                                    Button {
                                        editingTransaction = tx
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    Button {
                                        try? projectRepo.detach([tx])
                                        loadData()
                                    } label: {
                                        Label("移出项目", systemImage: "minus.circle")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 数据

    private func loadData() {
        totalExpense = projectRepo.totalExpense(forProject: project.id)
        expenseCount = projectRepo.fetchExpenseTransactions(forProject: project.id).count
        categoryAggregations = projectRepo.categoryAggregations(forProject: project.id)
        transactions = projectRepo.fetchTransactions(forProject: project.id)
        // 被过滤的分类可能已不在聚合里，兜底清空筛选
        if let filter = categoryFilter,
           !categoryAggregations.contains(where: { $0.category.id == filter.id }) {
            categoryFilter = nil
        }
    }

    private var dailyAverage: Decimal {
        let calendar = Calendar.current
        // 起点优先用项目开始日，否则用最早一笔交易；终点用结束日或今天
        let firstDay = calendar.startOfDay(for: project.startDate ?? transactions.last?.date ?? project.createdAt)
        let lastDay = calendar.startOfDay(for: project.endDate ?? Date())
        let days = max(1, (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1)
        return totalExpense / Decimal(days)
    }

    private func groupByDate(_ source: [Transaction]) -> [Date: [Transaction]] {
        Dictionary(grouping: source) { Calendar.current.startOfDay(for: $0.date) }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()
}

// MARK: - 从历史挑交易批量补挂

/// 列出未挂任何项目的支出交易，多选批量挂到本项目
struct ProjectHistoryPickerSheet: View {

    let project: FinanceProject
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [Transaction] = []
    @State private var selectedIds: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    VStack(spacing: HoloSpacing.md) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40, weight: .light))
                            .foregroundColor(.holoTextSecondary.opacity(0.5))
                        Text("近期没有可补挂的支出")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                        Text("已挂到其他项目的交易不会出现在这里")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: HoloSpacing.xs) {
                            ForEach(candidates, id: \.objectID) { tx in
                                historyRow(tx)
                            }
                        }
                        .padding(.horizontal, HoloSpacing.lg)
                    }
                }
            }
            .background(Color.holoBackground)
            .navigationTitle("选择交易")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("挂到项目 (\(selectedIds.count))") { attachSelected() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(selectedIds.isEmpty ? .holoTextSecondary : .holoPrimary)
                        .disabled(selectedIds.isEmpty)
                }
            }
            .onAppear {
                Task { await loadCandidates() }
            }
        }
        .presentationDetents([.large])
    }

    private func historyRow(_ tx: Transaction) -> some View {
        let isSelected = selectedIds.contains(tx.id)
        return Button {
            if isSelected {
                selectedIds.remove(tx.id)
            } else {
                selectedIds.insert(tx.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary.opacity(0.5))

                TransactionRowView(transaction: tx, showsDate: true) {}
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadCandidates() async {
        let all = (try? await FinanceRepository.shared.getAllTransactions()) ?? []
        candidates = all
            .filter { $0.transactionType == .expense && $0.financeProjectId == nil }
            .prefix(200)
            .map { $0 }
    }

    private func attachSelected() {
        let targets = candidates.filter { selectedIds.contains($0.id) }
        try? FinanceProjectRepository.shared.attach(targets, to: project)
        onComplete()
        dismiss()
    }
}
