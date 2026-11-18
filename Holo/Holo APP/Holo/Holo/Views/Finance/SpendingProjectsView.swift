//
//  SpendingProjectsView.swift
//  Holo
//
//  固定支出（原"长期成本"）—— 财务模块底部第 4 个 Tab
//  管理订阅、会员等周期性支出与耐用品等一次性购买的使用成本
//

import SwiftUI
import CoreData

// MARK: - SpendingProjectsView

/// 固定支出主视图（Tab 页）
struct SpendingProjectsView: View {
    /// 返回上一级（与其他 Tab 一致的返回交互）
    let onBack: () -> Void
    @State private var projects: [SpendingProject] = []
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    summaryCard
                    projectSection(String(localized: "周期性项目"), projects.filter(\.isRecurring))
                    projectSection(String(localized: "一次性购买"), projects.filter { !$0.isRecurring })
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                // 底部避让（2026-11-18 东林实报「划不到最底层」根因修复）：
                // NavigationStack 根 ScrollView 在本容器里不会把财务底栏的
                // safeAreaInset 变成滚动避让——内容停靠时零间隙压在不透明底栏
                // 下面（像素实测：最后一行被栏盖住 2/3 字身）。与设置页
                // .padding(.bottom, 100) 同款同病灶；120=底栏实测高（122pt 圆整）
                .padding(.bottom, 120)
            }
            .background(Color.holoBackground)
            .navigationTitle("固定支出")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if canImport(UIKit)
            .toolbarBackground(Color.holoBackground, for: .navigationBar)
            #else
            // macOS：导航栏背景恒等
            #endif
            #if canImport(UIKit)
            .toolbarBackground(.visible, for: .navigationBar)
            #else
            // macOS：导航栏背景恒等
            #endif
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.topBarLeading) {
                    Button {
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
                    }
                }
                ToolbarItem(placement: HoloToolbarPlacement.topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddSpendingProjectSheet { refresh() } }
            .task { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in
                refresh()
            }
            .onAppear { refresh() }
        }
    }

    private var summaryCard: some View {
        let monthly = projects.compactMap(\.monthlyCommitment).reduce(Decimal(0), +)
        let daily = projects.filter { !$0.isRecurring }.compactMap(\.dailyCost).reduce(Decimal(0), +)
        return HStack(spacing: 0) {
            metric(String(localized: "每月承诺"), monthly)
            Divider().frame(height: 40)
            metric(String(localized: "一次性·折合每天"), daily)
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
            // 三列均分列宽有限：标题超长（如英文「One-time · Per Day」）不折行，轻微缩字
            Text(title).font(.holoLabel).foregroundColor(.holoTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
                ForEach(projects.renderable, id: \.objectID) { project in
                    NavigationLink { SpendingProjectDetailView(project: project) { refresh() } } label: {
                        projectRow(project)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func projectRow(_ project: SpendingProject) -> some View {
        return HStack(spacing: HoloSpacing.md) {
            SpendingProjectIconSlot(project: project)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.holoBody).foregroundColor(.holoTextPrimary).lineLimit(1)
                Text(project.isRecurring
                     ? "\(project.frequency == SpendingProjectFrequency.yearly.rawValue ? String(localized: "每年") : String(localized: "每月")) · \(project.isPaused ? String(localized: "已暂停") : (project.hasRemainingOccurrences ? String(localized: "自动记账") : String(localized: "已完成")))"
                     : String(localized: "已购 \(project.ownershipElapsedDays) 天"))
                    .font(.system(size: 12)).foregroundColor(.holoTextSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(NumberFormatter.currency.string(from: project.amount) ?? "¥0")
                    .font(.holoBody).fontWeight(.semibold).foregroundColor(.holoTextPrimary)
                if let cost = project.isRecurring ? project.monthlyCommitment : project.dailyCost {
                    Text(project.isRecurring ? String(localized: "月均 \(NumberFormatter.currency.string(from: cost as NSDecimalNumber) ?? "¥0")") : String(localized: "日均 \(NumberFormatter.currency.string(from: cost as NSDecimalNumber) ?? "¥0")"))
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
        FinanceRepository.shared.migrateFixedExpenseSemantics()
        try? SpendingProjectRepository.shared.syncRecurringProjects()
        try? SpendingProjectRepository.shared.syncOneOffProjects()
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
    /// 详情页直达换外观（单层 Sheet，选完立即生效——详情非表单，直改语义清晰）
    @State private var showAppearancePicker = false

    var body: some View {
        Form {
            SpendingProjectVisualSection(project: project, onTapChange: {
                showAppearancePicker = true
            })
            if !hasVisualPlacement {
                Section {
                    Button(String(localized: "设置外观")) { showAppearancePicker = true }
                        .foregroundColor(.holoPrimary)
                }
                .listRowBackground(Color.holoCardBackground)
            }
            Section {
                LabeledContent("类型", value: project.isRecurring ? "周期性支出" : "一次性购买")
                LabeledContent(project.isRecurring ? String(localized: "每期金额") : String(localized: "金额"), value: NumberFormatter.currency.string(from: project.amount) ?? "¥0")
                if project.isRecurring {
                    LabeledContent("发生周期", value: project.frequency == SpendingProjectFrequency.yearly.rawValue ? "每年" : "每月")
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
                Section { Button("编辑信息") { showOneOffEditor = true } }
                    .listRowBackground(Color.holoCardBackground)
                Section {
                    Text("仅用于计算持有天数和日均成本，不会生成账本流水，也不会计入消费或余额。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                .listRowBackground(Color.holoCardBackground)
            } else {
                Section {
                    Button("编辑周期项目") { showEndConditionEditor = true }
                    Button(project.isPaused ? String(localized: "恢复自动记账") : String(localized: "暂停自动记账")) { togglePause() }
                }
                .listRowBackground(Color.holoCardBackground)
            }
            if let errorMessage { Section { Text(errorMessage).foregroundColor(.holoToolError) }.listRowBackground(Color.holoCardBackground) }
        }
        .scrollContentBackground(.hidden)
        .background(Color.holoBackground)
        .tint(Color.holoPrimary)
        .navigationTitle(project.name)
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if canImport(UIKit)
        .toolbarBackground(Color.holoBackground, for: .navigationBar)
        #else
        // macOS：导航栏背景恒等
        #endif
        #if canImport(UIKit)
        .toolbarBackground(.visible, for: .navigationBar)
        #else
        // macOS：导航栏背景恒等
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            ToolbarItem(placement: .destructiveAction) { Button(role: .destructive) { showDeleteConfirmation = true } label: { Image(systemName: "trash") } }
        }
        .confirmationDialog(project.isRecurring ? String(localized: "删除这个固定支出项目？已生成的账本流水会保留。") : String(localized: "删除这个一次性购买项目？"), isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
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
        // 详情直达换外观：单层 Sheet，立即生效，失败如实提示（不吞错）
        .sheet(isPresented: $showAppearancePicker) {
            appearancePickerSheet
                .presentationBackground(Color.holoBackground)
        }
        .onDisappear { performPendingDeletion() }
    }

    private var hasVisualPlacement: Bool {
        if case .assetReady = project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext) {
            return true
        }
        return false
    }

    private var appearancePickerSheet: some View {
        let current = project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext)
        var inUse: UUID?
        if case .assetReady(let d) = current { inUse = d.assetID }
        return VisualAppearancePickerView(isPushed: false,
                                          pickerTitle: String(localized: "外观"),
                                          currentPlacement: current,
                                          inUseAssetID: inUse,
                                          onRestoreDefault: { applyAppearance(.clear) }) { assetID, presentation in
            applyAppearance(.setAsset(.asset(assetID), presentation: presentation))
        }
    }

    private func applyAppearance(_ payload: VisualPlacementPayload) {
        guard let ownerKey = project.visualOwnerKey else { return }
        let expectedWinner = project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext).winnerRevisionIDIfAny
        Task {
            do {
                _ = try await VisualCommitCoordinator.shared.commit(
                    .applyPlacement(operationID: UUID(),
                                    ownerKind: SpendingProject.visualOwnerKind,
                                    ownerKey: ownerKey,
                                    slot: SpendingProject.visualSlot,
                                    expectedSlotWinnerRevisionID: expectedWinner,
                                    payload: payload),
                    in: CoreDataStack.shared.persistentContainer)
            } catch {
                errorMessage = String(localized: "外观没有设置成功，请重试")
            }
        }
    }

    private func togglePause() { do { try SpendingProjectRepository.shared.updatePause(for: project, isPaused: !project.isPaused); onChanged() } catch { errorMessage = String(localized: "更新项目状态失败") } }
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
    private static let dateFormatter: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("yMMMd"); return f }()
}

struct SpendingProjectEndConditionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: SpendingProject
    let onSaved: () -> Void
    @State private var amount: String
    @State private var mode: SpendingProjectEndMode
    @State private var endDate: Date
    @State private var totalOccurrences: String
    @State private var errorMessage: String?
    /// 外观草稿：随「保存」统一提交（东林 11-18 拍板 B 逻辑）；取消=丢弃
    @State private var appearanceDraft: VisualAppearanceDraft = .none
    @State private var showAppearancePicker = false
    /// 金额/周期数输入聚焦态：数字键盘没有「完成」按钮，用 keyboard toolbar 提供
    @FocusState private var focusedField: Field?

    private enum Field { case amount, occurrences }

    init(project: SpendingProject, onSaved: @escaping () -> Void) {
        self.project = project
        self.onSaved = onSaved
        _amount = State(initialValue: NSDecimalNumber(decimal: project.amountDecimal).stringValue)
        _mode = State(initialValue: project.maxOccurrences > 0 ? .occurrenceCount : (project.endDate == nil ? .forever : .endDate))
        _endDate = State(initialValue: project.endDate ?? (Calendar.current.date(byAdding: .year, value: 1, to: project.startDate) ?? project.startDate))
        _totalOccurrences = State(initialValue: project.maxOccurrences > 0 ? "\(project.maxOccurrences)" : "12")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("金额") {
                    TextField("每期金额", text: $amount).keyboardType(.decimalPad).focused($focusedField, equals: .amount)
                    Text("新金额从下一次到期开始生效，已发生流水不会被改写。")
                        .font(.caption)
                        .foregroundColor(.holoTextSecondary)
                }
                .listRowBackground(Color.holoCardBackground)
                Section("外观") {
                    VisualAppearanceFormRow(draft: appearanceDraft,
                                            placementProvider: { project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext) }) {
                        showAppearancePicker = true
                    }
                }
                .listRowBackground(Color.holoCardBackground)
                Picker("结束条件", selection: $mode) { ForEach(SpendingProjectEndMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                if mode == .endDate { DatePicker(String(localized: "结束日期"), selection: $endDate, in: project.startDate..., displayedComponents: .date) }
                if mode == .occurrenceCount { TextField("总周期数", text: $totalOccurrences).keyboardType(.numberPad).focused($focusedField, equals: .occurrences) }
                if let errorMessage { Text(errorMessage).foregroundColor(.holoToolError) }
            }
            // 外观选择器走栈内 push（零二层 Sheet——Form Section 上的 .sheet 首开被
            // cell 重排回收宿主锚点，弹窗秒关，B1 根因）
            .navigationDestination(isPresented: $showAppearancePicker) {
                appearanceDestination
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoBackground)
            .tint(Color.holoPrimary)
            .navigationTitle("编辑周期项目")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if canImport(UIKit)
            .toolbarBackground(Color.holoBackground, for: .navigationBar)
            #else
            // macOS：导航栏背景恒等
            #endif
            #if canImport(UIKit)
            .toolbarBackground(.visible, for: .navigationBar)
            #else
            // macOS：导航栏背景恒等
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundColor(.holoToolTextSecondary) }
                            .accessibilityLabel(Text("关闭")) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
                // 数字键盘没有「完成」按钮，这里在键盘正上方提供一个
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
        }
    }

    /// 外观选择器（栈内 push）：选完回草稿，随「保存」统一生效
    private var appearanceDestination: some View {
        let current = project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext)
        var inUse: UUID?
        if case .assetReady(let d) = current { inUse = d.assetID }
        return VisualAppearancePickerView(isPushed: true,
                                          pickerTitle: String(localized: "外观"),
                                          currentPlacement: current,
                                          inUseAssetID: inUse,
                                          onRestoreDefault: {
                                          appearanceDraft = .cleared
                                          showAppearancePicker = false
                                      }) { assetID, presentation in
            appearanceDraft = .set(assetID: assetID, presentation: presentation)
            showAppearancePicker = false
        }
    }

    private func save() {
        guard let amountValue = Decimal(string: amount), amountValue > 0 else {
            errorMessage = String(localized: "请输入有效的每期金额")
            return
        }
        let maxOccurrences = mode == .occurrenceCount ? (Int32(totalOccurrences) ?? 0) : 0
        guard mode == .forever || mode == .endDate || maxOccurrences > 0 else { errorMessage = String(localized: "请输入有效周期数"); return }
        do {
            try SpendingProjectRepository.shared.updateRecurringProject(
                project,
                amount: amountValue,
                endDate: mode == .endDate ? endDate : nil,
                maxOccurrences: maxOccurrences
            )
            onSaved()
            commitAppearanceDraftThenDismiss()
        } catch { errorMessage = String(localized: "保存失败，请稍后重试") }
    }

    /// 外观草稿随保存收口：提交失败如实提示、表单不关（可重试保存）；取消则丢弃草稿
    private func commitAppearanceDraftThenDismiss() {
        let draft = appearanceDraft
        guard draft != .none, let ownerKey = project.visualOwnerKey else {
            dismiss()
            return
        }
        let expectedWinner = project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext).winnerRevisionIDIfAny
        Task {
            do {
                try await draft.commit(ownerKind: SpendingProject.visualOwnerKind,
                                       ownerKey: ownerKey,
                                       slot: SpendingProject.visualSlot,
                                       expectedSlotWinnerRevisionID: expectedWinner,
                                       in: CoreDataStack.shared.persistentContainer)
                dismiss()
            } catch {
                errorMessage = String(localized: "项目已保存，但外观没有设置成功，可以重试保存")
            }
        }
    }
}

struct SpendingProjectOneOffEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: SpendingProject
    let onSaved: () -> Void
    @State private var name: String
    @State private var amount: String
    @State private var purchaseDate: Date
    @State private var selectedCategory: Category?
    @State private var errorMessage: String?
    /// 外观草稿：随「保存」统一提交；取消=丢弃
    @State private var appearanceDraft: VisualAppearanceDraft = .none
    @State private var showAppearancePicker = false
    /// 金额输入聚焦态：数字键盘没有「完成」按钮，用 keyboard toolbar 提供
    @FocusState private var isAmountFocused: Bool

    init(project: SpendingProject, onSaved: @escaping () -> Void) {
        self.project = project
        self.onSaved = onSaved
        _name = State(initialValue: project.name)
        _amount = State(initialValue: NSDecimalNumber(decimal: project.amountDecimal).stringValue)
        _purchaseDate = State(initialValue: project.startDate)
        _selectedCategory = State(initialValue: project.categoryId.flatMap { FinanceRepository.shared.findCategory(by: $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("购买信息") {
                    TextField("商品名称", text: $name)
                    TextField("购买金额", text: $amount).keyboardType(.decimalPad).focused($isAmountFocused)
                    DatePicker(String(localized: "购买日期"), selection: $purchaseDate, displayedComponents: .date)
                }
                .listRowBackground(Color.holoCardBackground)
                Section("外观") {
                    VisualAppearanceFormRow(draft: appearanceDraft,
                                            placementProvider: { project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext) }) {
                        showAppearancePicker = true
                    }
                }
                .listRowBackground(Color.holoCardBackground)
                Section("分类") {
                    CategoryPicker(selectedCategory: $selectedCategory, transactionType: .constant(.expense), showsTypeTabs: false)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.holoCardBackground)
                }
                Section {
                    Text("仅用于计算持有天数和日均成本，不会生成账本流水，也不会计入消费或余额。")
                        .font(.caption)
                        .foregroundColor(.holoTextSecondary)
                }
                .listRowBackground(Color.holoCardBackground)
                if let errorMessage { Section { Text(errorMessage).foregroundColor(.holoToolError) }.listRowBackground(Color.holoCardBackground) }
            }
            .navigationDestination(isPresented: $showAppearancePicker) {
                appearanceDestination
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoBackground)
            .tint(Color.holoPrimary)
            .navigationTitle("编辑一次性购买")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if canImport(UIKit)
            .toolbarBackground(Color.holoBackground, for: .navigationBar)
            #else
            // macOS：导航栏背景恒等
            #endif
            #if canImport(UIKit)
            .toolbarBackground(.visible, for: .navigationBar)
            #else
            // macOS：导航栏背景恒等
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundColor(.holoToolTextSecondary) }
                            .accessibilityLabel(Text("关闭")) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
                // 数字键盘没有「完成」按钮，这里在键盘正上方提供一个
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isAmountFocused = false }
                }
            }
        }
    }

    /// 外观选择器（栈内 push）：选完回草稿，随「保存」统一生效
    private var appearanceDestination: some View {
        let current = project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext)
        var inUse: UUID?
        if case .assetReady(let d) = current { inUse = d.assetID }
        return VisualAppearancePickerView(isPushed: true,
                                          pickerTitle: String(localized: "外观"),
                                          currentPlacement: current,
                                          inUseAssetID: inUse,
                                          onRestoreDefault: {
                                          appearanceDraft = .cleared
                                          showAppearancePicker = false
                                      }) { assetID, presentation in
            appearanceDraft = .set(assetID: assetID, presentation: presentation)
            showAppearancePicker = false
        }
    }

    private func save() {
        guard let value = Decimal(string: amount), value > 0,
              let selectedCategory,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = String(localized: "请填写有效的名称、金额和分类")
            return
        }
        do {
            try SpendingProjectRepository.shared.updateOneOffProject(project, name: name, amount: value, purchaseDate: purchaseDate, category: selectedCategory)
            onSaved()
            commitAppearanceDraftThenDismiss()
        } catch {
            errorMessage = String(localized: "保存失败，请稍后重试")
        }
    }

    /// 外观草稿随保存收口：提交失败如实提示、表单不关（可重试保存）；取消则丢弃草稿
    private func commitAppearanceDraftThenDismiss() {
        let draft = appearanceDraft
        guard draft != .none, let ownerKey = project.visualOwnerKey else {
            dismiss()
            return
        }
        let expectedWinner = project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext).winnerRevisionIDIfAny
        Task {
            do {
                try await draft.commit(ownerKind: SpendingProject.visualOwnerKind,
                                       ownerKey: ownerKey,
                                       slot: SpendingProject.visualSlot,
                                       expectedSlotWinnerRevisionID: expectedWinner,
                                       in: CoreDataStack.shared.persistentContainer)
                dismiss()
            } catch {
                errorMessage = String(localized: "项目已保存，但外观没有设置成功，可以重试保存")
            }
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
    @State private var selectedCategory: Category?
    @State private var errorMessage: String?
    /// 外观候选：新项目还没有 id，选完暂存、保存时绑定（东林拍板「立即生效」在编辑场景；
    /// 新增场景对象不存在，只能保存收口——物理限制）
    @State private var appearanceDraft: VisualAppearanceDraft = .none
    @State private var showAppearancePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("类型") {
                    Picker("项目类型", selection: $kind) { Text("周期性支出").tag(SpendingProjectKind.recurring); Text("一次性购买").tag(SpendingProjectKind.oneOff) }.pickerStyle(.segmented)
                    TextField("名称，例如 年度旅行 / 新电脑", text: $name)
                    TextField(kind == .recurring ? String(localized: "每期金额") : String(localized: "购买金额"), text: $amount).keyboardType(.decimalPad)
                }
                .listRowBackground(Color.holoCardBackground)
                Section("外观") {
                    VisualAppearanceFormRow(draft: appearanceDraft, currentPlacement: nil,
                                            fallbackIcon: selectedCategory.map { _ in "bag.fill" } ?? "bag.fill") {
                        showAppearancePicker = true
                    }
                }
                .listRowBackground(Color.holoCardBackground)
                Section("分类") {
                    CategoryPicker(selectedCategory: $selectedCategory, transactionType: .constant(.expense), showsTypeTabs: false)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.holoCardBackground)
                }
                Section("规则") {
                    DatePicker(kind == .oneOff ? String(localized: "购买日期") : String(localized: "开始日期"), selection: $startDate, displayedComponents: .date)
                    if kind == .recurring {
                        Picker("发生周期", selection: $frequency) { ForEach(SpendingProjectFrequency.allCases, id: \.self) { Text($0.title).tag($0) } }
                        Picker("结束条件", selection: $endMode) { ForEach(SpendingProjectEndMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                        if endMode == .endDate { DatePicker(String(localized: "结束日期"), selection: $endDate, in: startDate..., displayedComponents: .date) }
                        if endMode == .occurrenceCount { TextField("总周期数", text: $totalOccurrences).keyboardType(.numberPad) }
                        Text("每次到期记录一笔每期金额，未来期次不会提前入账。")
                            .font(.caption)
                            .foregroundColor(.holoTextSecondary)
                    } else {
                        Text("仅用于计算持有天数和日均成本，不会生成账本流水，也不会计入消费或余额。")
                            .font(.caption)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                .listRowBackground(Color.holoCardBackground)
                if let errorMessage { Text(errorMessage).foregroundColor(.holoToolError).listRowBackground(Color.holoCardBackground) }
            }
            .navigationDestination(isPresented: $showAppearancePicker) {
                VisualAppearancePickerView(isPushed: true,
                                           pickerTitle: String(localized: "外观"),
                                           onRestoreDefault: {
                                           appearanceDraft = .cleared
                                           showAppearancePicker = false
                                       }) { assetID, presentation in
                    appearanceDraft = .set(assetID: assetID, presentation: presentation)
                    showAppearancePicker = false
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoBackground)
            .tint(Color.holoPrimary)
            .navigationTitle("添加固定支出")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).foregroundColor(.holoToolTextSecondary) }
                            .accessibilityLabel(Text("关闭")) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Decimal(string: amount) == nil) }
            }
            .presentationBackground(Color.holoBackground)
        }
    }

    private func save() {
        guard let value = Decimal(string: amount), value > 0 else { errorMessage = String(localized: "请输入有效金额"); return }
        guard let selectedCategory else { errorMessage = String(localized: "请选择消费分类"); return }
        do {
            let finance = FinanceRepository.shared
            let account = kind == .recurring ? finance.getDefaultAccountSync() : nil
            let maxOccurrences = kind == .recurring && endMode == .occurrenceCount ? (Int32(totalOccurrences) ?? 0) : 0
            let projectEndDate = kind == .recurring && endMode == .endDate ? endDate : nil
            guard kind == .oneOff || endMode == .forever || projectEndDate != nil || maxOccurrences > 0 else { errorMessage = String(localized: "请设置有效的结束条件"); return }
            let project = try SpendingProjectRepository.shared.create(name: name, kind: kind, amount: value, frequency: kind == .recurring ? frequency : nil, startDate: startDate, endDate: projectEndDate, maxOccurrences: maxOccurrences, plannedLifespanDays: 0, category: selectedCategory, account: account)
            // 外观候选随保存收口绑定：失败如实提示（新对象无赢家，基线 nil）
            let draft = appearanceDraft
            if let key = project.visualOwnerKey, draft != .none {
                Task {
                    do {
                        try await draft.commit(ownerKind: SpendingProject.visualOwnerKind, ownerKey: key,
                                               slot: SpendingProject.visualSlot,
                                               in: CoreDataStack.shared.persistentContainer)
                    } catch {
                        errorMessage = String(localized: "项目已保存，但外观没有设置成功")
                    }
                }
            }
            onSaved(); dismiss()
        } catch { errorMessage = String(localized: "保存失败，请稍后重试") }
    }
}

