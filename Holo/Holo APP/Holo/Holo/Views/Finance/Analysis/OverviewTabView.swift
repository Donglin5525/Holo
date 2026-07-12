//
//  OverviewTabView.swift
//  Holo
//
//  总览 Tab 视图
//  包含柱状图 + TOP3 分类卡片
//

import SwiftUI
import CoreData

// MARK: - OverviewTabView

/// 总览 Tab 视图
struct OverviewTabView: View {
    @ObservedObject var state: FinanceAnalysisState
    var onSpendingProjectsTap: (() -> Void)? = nil
    var onCategoryTap: ((Category) -> Void)? = nil

    /// 计算余额坐标缩放（将余额映射到收支 Y 轴范围）
    private var balanceScale: BalanceChartScale? {
        let points = state.chartDataPoints
        guard !points.isEmpty else { return nil }
        let amountValues = points.flatMap { [
            Double(truncating: $0.expense as NSDecimalNumber),
            Double(truncating: $0.income as NSDecimalNumber)
        ] }
        let balanceValues = points.map {
            Double(truncating: $0.balance as NSDecimalNumber)
        }
        return BalanceChartScale(amountValues: amountValues, balanceValues: balanceValues)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                // 周期汇总卡片
                periodSummaryCard

                spendingProjectsCard

                // 柱状图（含余额折线，双 Y 轴）
                BarChartView(
                    dataPoints: state.chartDataPoints,
                    showBalance: true,
                    balanceScale: balanceScale
                )

                // TOP3 分类
                TopCategoryCard(
                    expenseAggregations: state.expenseCategoryAggregations,
                    incomeAggregations: state.incomeCategoryAggregations
                ) { category in
                    onCategoryTap?(category)
                }
            }
            .padding(HoloSpacing.lg)
        }
        .background(Color.holoBackground)
    }

    // MARK: - 周期汇总卡片

    private var periodSummaryCard: some View {
        HStack(spacing: 0) {
            // 支出
            PeriodSummaryItem(
                title: "总支出",
                amount: state.periodSummary.formattedExpense,
                subtitle: "日均 \(NumberFormatter.currency.string(from: state.periodSummary.averageDailyExpense as NSDecimalNumber) ?? "¥0")",
                color: .holoError
            )

            Divider()
                .frame(height: 40)

            // 收入
            PeriodSummaryItem(
                title: "总收入",
                amount: state.periodSummary.formattedIncome,
                subtitle: "日均 \(NumberFormatter.currency.string(from: state.periodSummary.averageDailyIncome as NSDecimalNumber) ?? "¥0")",
                color: .holoSuccess
            )

            Divider()
                .frame(height: 40)

            // 净收入
            PeriodSummaryItem(
                title: "净收入",
                amount: state.periodSummary.formattedNetIncome,
                subtitle: "\(state.periodSummary.transactionCount) 笔",
                color: state.periodSummary.netIncome >= 0 ? .holoSuccess : .holoError
            )
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var spendingProjectsCard: some View {
        let projects = SpendingProjectRepository.shared.allProjects()
        let monthly = projects.compactMap(\.monthlyCommitment).reduce(Decimal(0), +)
        let daily = projects.filter { !$0.isRecurring }.compactMap(\.dailyCost).reduce(Decimal(0), +)
        return Button {
            onSpendingProjectsTap?()
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: "repeat.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.holoPrimary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("长期成本").font(.holoBody).foregroundColor(.holoTextPrimary)
                    Text(projects.isEmpty ? "记录订阅、耐用品与使用成本" : "每月承诺 \(NumberFormatter.currency.string(from: monthly as NSDecimalNumber) ?? "¥0") · 一次性日均 \(NumberFormatter.currency.string(from: daily as NSDecimalNumber) ?? "¥0")")
                        .font(.system(size: 12)).foregroundColor(.holoTextSecondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.holoTextSecondary)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Period Summary Item

/// 周期汇总项
struct PeriodSummaryItem: View {
    let title: String
    let amount: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(spacing: HoloSpacing.xs) {
            Text(title)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            Text(amount)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(color)
                .lineLimit(1)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview {
    OverviewTabView(state: FinanceAnalysisState())
}

// MARK: - 长期成本

struct SpendingProjectsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [SpendingProject] = []
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    summaryCard
                    projectSection("周期性项目", projects.filter(\.isRecurring))
                    projectSection("一次性购买", projects.filter { !$0.isRecurring })
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("长期成本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.holoBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button { showAdd = true } label: { Image(systemName: "plus") } }
            }
            .sheet(isPresented: $showAdd) { AddSpendingProjectSheet { refresh() } }
            .task { refresh() }
            .onAppear { refresh() }
        }
    }

    private var summaryCard: some View {
        let monthly = projects.compactMap(\.monthlyCommitment).reduce(Decimal(0), +)
        let daily = projects.filter { !$0.isRecurring }.compactMap(\.dailyCost).reduce(Decimal(0), +)
        return HStack(spacing: 0) {
            metric("每月承诺", monthly)
            Divider().frame(height: 40)
            metric("一次性日均", daily)
            Divider().frame(height: 40)
            VStack(spacing: 4) {
                Text("项目数").font(.holoLabel).foregroundColor(.holoTextSecondary)
                Text("\(projects.count)").font(.system(size: 18, weight: .bold)).foregroundColor(.holoTextPrimary)
                Text("项").font(.system(size: 11)).foregroundColor(.holoTextSecondary)
            }.frame(maxWidth: .infinity)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private func metric(_ title: String, _ value: Decimal) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.holoLabel).foregroundColor(.holoTextSecondary)
            Text(NumberFormatter.currency.string(from: value as NSDecimalNumber) ?? "¥0").font(.system(size: 16, weight: .bold)).foregroundColor(.holoPrimary).lineLimit(1)
            Text("当前").font(.system(size: 11)).foregroundColor(.holoTextSecondary)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func projectSection(_ title: String, _ projects: [SpendingProject]) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(title).font(.holoBody).fontWeight(.semibold).foregroundColor(.holoTextPrimary)
            if projects.isEmpty {
                Text("还没有项目，点击右上角 + 添加")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(HoloSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            } else {
                ForEach(projects, id: \.objectID) { project in
                    NavigationLink { SpendingProjectDetailView(project: project) { refresh() } } label: {
                        projectRow(project)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func projectRow(_ project: SpendingProject) -> some View {
        let category = project.categoryId.flatMap { FinanceRepository.shared.findCategory(by: $0) }
        return HStack(spacing: HoloSpacing.md) {
            if let category, !category.isDeleted {
                CategoryIconBadge(category: category, diameter: 42)
            } else {
                CategoryIconBadge(iconName: "bag.fill", color: .holoTextSecondary, diameter: 42)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.holoBody).foregroundColor(.holoTextPrimary).lineLimit(1)
                Text(project.isRecurring
                     ? "\(project.frequency == SpendingProjectFrequency.yearly.rawValue ? "每年" : "每月") · \(project.isPaused ? "已暂停" : (project.hasRemainingOccurrences ? "自动记账" : "已完成"))"
                     : "已购 \(project.ownershipElapsedDays) 天")
                    .font(.system(size: 12)).foregroundColor(.holoTextSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(NumberFormatter.currency.string(from: project.amount) ?? "¥0")
                    .font(.holoBody).fontWeight(.semibold).foregroundColor(.holoTextPrimary)
                if let cost = project.isRecurring ? project.monthlyCommitment : project.dailyCost {
                    Text(project.isRecurring ? "月均 \(NumberFormatter.currency.string(from: cost as NSDecimalNumber) ?? "¥0")" : "日均 \(NumberFormatter.currency.string(from: cost as NSDecimalNumber) ?? "¥0")")
                        .font(.system(size: 11)).foregroundColor(.holoTextSecondary)
                }
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(.holoTextSecondary)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private func refresh() {
        try? SpendingProjectRepository.shared.syncRecurringProjects()
        projects = SpendingProjectRepository.shared.allProjects()
    }
}

struct SpendingProjectDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let project: SpendingProject
    let onChanged: () -> Void
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var showEndConditionEditor = false
    @State private var showOneOffEditor = false
    @State private var pendingDeletionID: NSManagedObjectID?

    var body: some View {
        Form {
            Section {
                LabeledContent("类型", value: project.isRecurring ? "周期性支出" : "一次性购买")
                LabeledContent("金额", value: NumberFormatter.currency.string(from: project.amount) ?? "¥0")
                if project.isRecurring {
                    LabeledContent("月均承诺", value: NumberFormatter.currency.string(from: (project.monthlyCommitment ?? Decimal(0)) as NSDecimalNumber) ?? "¥0")
                    LabeledContent("下次扣款", value: project.nextOccurrenceDate.map { Self.dateFormatter.string(from: $0) } ?? "未设置")
                } else {
                    LabeledContent("购买日期", value: Self.dateFormatter.string(from: project.startDate))
                    LabeledContent("已购天数", value: "\(project.ownershipElapsedDays) 天")
                    LabeledContent("当前日均", value: NumberFormatter.currency.string(from: (project.dailyCost ?? 0) as NSDecimalNumber) ?? "¥0")
                }
            }
            .listRowBackground(Color.holoCardBackground)
            if !project.isRecurring {
                Section { Button("编辑购买信息") { showOneOffEditor = true } }
                    .listRowBackground(Color.holoCardBackground)
            } else {
                Section {
                    Button("设置结束条件") { showEndConditionEditor = true }
                    Button(project.isPaused ? "恢复自动记账" : "暂停自动记账") { togglePause() }
                }
                .listRowBackground(Color.holoCardBackground)
            }
            if let errorMessage { Section { Text(errorMessage).foregroundColor(.red) }.listRowBackground(Color.holoCardBackground) }
        }
        .scrollContentBackground(.hidden)
        .background(Color.holoBackground)
        .tint(Color.holoPrimary)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.holoBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            ToolbarItem(placement: .destructiveAction) { Button(role: .destructive) { showDeleteConfirmation = true } label: { Image(systemName: "trash") } }
        }
        .confirmationDialog("删除这个长期成本项目？已生成的账本流水会保留。", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除项目", role: .destructive) {
                deleteProject()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showEndConditionEditor) {
            SpendingProjectEndConditionSheet(project: project) { onChanged() }
                .presentationBackground(Color.holoBackground)
        }
        .sheet(isPresented: $showOneOffEditor) {
            SpendingProjectOneOffEditorSheet(project: project) { onChanged() }
                .presentationBackground(Color.holoBackground)
        }
        .onDisappear { performPendingDeletion() }
    }

    private func togglePause() { do { try SpendingProjectRepository.shared.updatePause(for: project, isPaused: !project.isPaused); onChanged() } catch { errorMessage = "更新项目状态失败" } }
    private func deleteProject() {
        pendingDeletionID = project.objectID
        dismiss()
    }

    private func performPendingDeletion() {
        guard let projectID = pendingDeletionID else { return }
        pendingDeletionID = nil
        do {
            try SpendingProjectRepository.shared.deleteProject(id: projectID)
            onChanged()
        } catch {
            // 详情页已关闭，避免对已消失视图回写状态；下次进入列表可重试删除。
        }
    }
    private static let dateFormatter: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日"; return f }()
}

struct SpendingProjectEndConditionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: SpendingProject
    let onSaved: () -> Void
    @State private var mode: SpendingProjectEndMode
    @State private var endDate: Date
    @State private var totalOccurrences: String
    @State private var errorMessage: String?

    init(project: SpendingProject, onSaved: @escaping () -> Void) {
        self.project = project
        self.onSaved = onSaved
        _mode = State(initialValue: project.maxOccurrences > 0 ? .occurrenceCount : (project.endDate == nil ? .forever : .endDate))
        _endDate = State(initialValue: project.endDate ?? (Calendar.current.date(byAdding: .year, value: 1, to: project.startDate) ?? project.startDate))
        _totalOccurrences = State(initialValue: project.maxOccurrences > 0 ? "\(project.maxOccurrences)" : "12")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("结束条件", selection: $mode) { ForEach(SpendingProjectEndMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                if mode == .endDate { DatePicker("结束日期", selection: $endDate, in: project.startDate..., displayedComponents: .date) }
                if mode == .occurrenceCount { TextField("总周期数", text: $totalOccurrences).keyboardType(.numberPad) }
                if let errorMessage { Text(errorMessage).foregroundColor(.red) }
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoBackground)
            .tint(Color.holoPrimary)
            .navigationTitle("结束条件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.holoBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
        }
    }

    private func save() {
        let maxOccurrences = mode == .occurrenceCount ? (Int32(totalOccurrences) ?? 0) : 0
        guard mode == .forever || mode == .endDate || maxOccurrences > 0 else { errorMessage = "请输入有效周期数"; return }
        do {
            try SpendingProjectRepository.shared.updateEndCondition(for: project, endDate: mode == .endDate ? endDate : nil, maxOccurrences: maxOccurrences)
            onSaved(); dismiss()
        } catch { errorMessage = "保存失败，请稍后重试" }
    }
}

struct SpendingProjectOneOffEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: SpendingProject
    let onSaved: () -> Void
    @State private var name: String
    @State private var amount: String
    @State private var purchaseDate: Date
    @State private var categories: [Category] = []
    @State private var selectedCategory: Category?
    @State private var errorMessage: String?

    init(project: SpendingProject, onSaved: @escaping () -> Void) {
        self.project = project
        self.onSaved = onSaved
        _name = State(initialValue: project.name)
        _amount = State(initialValue: NSDecimalNumber(decimal: project.amountDecimal).stringValue)
        _purchaseDate = State(initialValue: project.startDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("购买信息") {
                    TextField("商品名称", text: $name)
                    TextField("购买金额", text: $amount).keyboardType(.decimalPad)
                    DatePicker("购买日期", selection: $purchaseDate, displayedComponents: .date)
                    SpendingProjectCategoryMenu(categories: categories, selectedCategory: $selectedCategory)
                }
                .listRowBackground(Color.holoCardBackground)
                if let errorMessage { Section { Text(errorMessage).foregroundColor(.holoError) }.listRowBackground(Color.holoCardBackground) }
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoBackground)
            .tint(Color.holoPrimary)
            .navigationTitle("编辑一次性购买")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.holoBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .onAppear { loadCategories() }
        }
    }

    private func save() {
        guard let value = Decimal(string: amount), value > 0,
              let selectedCategory,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请填写有效的名称、金额和分类"
            return
        }
        do {
            try SpendingProjectRepository.shared.updateOneOffProject(project, name: name, amount: value, purchaseDate: purchaseDate, category: selectedCategory)
            onSaved()
            dismiss()
        } catch {
            errorMessage = "保存失败，请稍后重试"
        }
    }

    private func loadCategories() {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "type == %@ AND parentId != nil", TransactionType.expense.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        categories = (try? FinanceRepository.shared.context.fetch(request)) ?? []
        if selectedCategory == nil, let categoryId = project.categoryId {
            selectedCategory = FinanceRepository.shared.findCategory(by: categoryId)
        }
    }
}

struct AddSpendingProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void
    @State private var kind: SpendingProjectKind = .recurring
    @State private var name = ""
    @State private var amount = ""
    @State private var frequency: SpendingProjectFrequency = .monthly
    @State private var startDate = Date()
    @State private var endMode: SpendingProjectEndMode = .forever
    @State private var endDate = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var totalOccurrences = "12"
    @State private var categories: [Category] = []
    @State private var selectedCategory: Category?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("类型") {
                    Picker("项目类型", selection: $kind) { Text("周期性支出").tag(SpendingProjectKind.recurring); Text("一次性购买").tag(SpendingProjectKind.oneOff) }.pickerStyle(.segmented)
                    TextField("名称，例如 ChatGPT / MacBook Pro", text: $name)
                    TextField("金额", text: $amount).keyboardType(.decimalPad)
                    SpendingProjectCategoryMenu(categories: categories, selectedCategory: $selectedCategory)
                }
                .listRowBackground(Color.holoCardBackground)
                Section("规则") {
                    DatePicker(kind == .oneOff ? "购买日期" : "开始日期", selection: $startDate, displayedComponents: .date)
                    if kind == .recurring {
                        Picker("发生周期", selection: $frequency) { ForEach(SpendingProjectFrequency.allCases, id: \.self) { Text($0.title).tag($0) } }
                        Picker("结束条件", selection: $endMode) { ForEach(SpendingProjectEndMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                        if endMode == .endDate { DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: .date) }
                        if endMode == .occurrenceCount { TextField("总周期数", text: $totalOccurrences).keyboardType(.numberPad) }
                    } else {
                        Text("日均成本会根据购买日期到今天的实际天数计算").font(.caption).foregroundColor(.holoTextSecondary)
                    }
                }
                .listRowBackground(Color.holoCardBackground)
                if let errorMessage { Text(errorMessage).foregroundColor(.holoError).listRowBackground(Color.holoCardBackground) }
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoBackground)
            .tint(Color.holoPrimary)
            .navigationTitle("添加长期成本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Decimal(string: amount) == nil) }
            }
            .presentationBackground(Color.holoBackground)
            .onAppear { loadCategories() }
        }
    }

    private func save() {
        guard let value = Decimal(string: amount), value > 0 else { errorMessage = "请输入有效金额"; return }
        guard let selectedCategory else { errorMessage = "请选择消费分类"; return }
        do {
            let finance = FinanceRepository.shared
            let account = finance.getDefaultAccountSync()
            let maxOccurrences = kind == .recurring && endMode == .occurrenceCount ? (Int32(totalOccurrences) ?? 0) : 0
            let projectEndDate = kind == .recurring && endMode == .endDate ? endDate : nil
            guard kind == .oneOff || endMode == .forever || projectEndDate != nil || maxOccurrences > 0 else { errorMessage = "请设置有效的结束条件"; return }
            _ = try SpendingProjectRepository.shared.create(name: name, kind: kind, amount: value, frequency: kind == .recurring ? frequency : nil, startDate: startDate, endDate: projectEndDate, maxOccurrences: maxOccurrences, plannedLifespanDays: 0, category: selectedCategory, account: account)
            onSaved(); dismiss()
        } catch { errorMessage = "保存失败，请稍后重试" }
    }

    private func loadCategories() {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "type == %@ AND parentId != nil", TransactionType.expense.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        categories = (try? FinanceRepository.shared.context.fetch(request)) ?? []
    }
}

/// 长期成本复用财务二级分类，分类图标即项目图标。
struct SpendingProjectCategoryMenu: View {
    let categories: [Category]
    @Binding var selectedCategory: Category?

    var body: some View {
        Menu {
            ForEach(categories, id: \.objectID) { category in
                Button(category.name) { selectedCategory = category }
            }
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                if let selectedCategory {
                    CategoryIconBadge(category: selectedCategory, diameter: 28)
                    Text(selectedCategory.name).foregroundColor(.holoTextPrimary)
                } else {
                    CategoryIconBadge(iconName: "bag.fill", color: .holoTextSecondary, diameter: 28)
                    Text("选择消费分类").foregroundColor(.holoTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .medium)).foregroundColor(.holoTextSecondary)
            }
        }
    }
}
