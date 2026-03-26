//
//  CategoryManagementView.swift
//  Holo
//
//  分类管理页面
//  支持支出/收入 Tab、一级与二级分类展示、新增/编辑/删除（预设不可删）
//

import SwiftUI
import CoreData
import OSLog

/// 分类管理视图
struct CategoryManagementView: View {

    @Environment(\.dismiss) var dismiss
    private let repository = FinanceRepository.shared
    private static let logger = Logger(subsystem: "com.holo.app", category: "CategoryManagement")
    
    @State private var transactionType: TransactionType = .expense
    @State private var topLevelCategories: [Category] = []
    @State private var subCategoriesMap: [UUID: [Category]] = [:]
    @State private var showAddCategory = false
    @State private var editingCategory: Category?
    @State private var categoryToDelete: Category?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCleanupConfirmation = false
    @State private var cleanupResult: (deleted: Int, skipped: Int)?
    
    var body: some View {
        VStack(spacing: 0) {
            // 支出/收入 Tab
            typePicker

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                List {
                    ForEach(topLevelCategories, id: \.id) { parent in
                        Section {
                            // 一级分类行（仅展示，不可选删除因有子分类）
                            categoryRow(parent, isParent: true)

                            // 二级子分类
                            ForEach(subCategoriesMap[parent.id] ?? [], id: \.id) { child in
                                categoryRow(child, isParent: false)
                            }
                        } header: {
                            Text(parent.name)
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("分类管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: HoloSpacing.sm) {
                    // 清理导入分类按钮
                    Button {
                        showCleanupConfirmation = true
                    } label: {
                        Image(systemName: "broom")
                            .font(.system(size: 18))
                            .foregroundColor(.orange)
                    }
                    // 新增分类按钮
                    Button {
                        showAddCategory = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddCategory) {
            AddCategorySheet(parentId: nil, type: transactionType) {
                Task { await loadData() }
            }
        }
        .sheet(item: $editingCategory) { category in
            EditCategorySheet(category: category) {
                Task { await loadData() }
            }
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("确认删除", isPresented: Binding(
            get: { categoryToDelete != nil },
            set: { if !$0 { categoryToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let cat = categoryToDelete {
                    confirmDelete(cat)
                }
                categoryToDelete = nil
            }
            Button("取消", role: .cancel) {
                categoryToDelete = nil
            }
        } message: {
            Text("删除后无法恢复；若该分类已被交易使用，将无法删除。")
        }
        // 清理导入分类确认
        .confirmationDialog("清理导入分类", isPresented: $showCleanupConfirmation, titleVisibility: .visible) {
            Button("清理", role: .destructive) {
                Task { await cleanupImportedCategories() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有导入时自动创建的分类（非预设分类），已被交易使用的分类会被保留。")
        }
        // 清理结果提示
        .alert("清理完成", isPresented: Binding(
            get: { cleanupResult != nil },
            set: { if !$0 { cleanupResult = nil } }
        )) {
            Button("确定") { cleanupResult = nil }
        } message: {
            if let result = cleanupResult {
                Text("已删除 \(result.deleted) 个分类\(result.skipped > 0 ? "，\(result.skipped) 个因被使用而保留" : "")")
            } else {
                Text("")
            }
        }
        .task {
            await loadData()
        }
    }
    
    private var typePicker: some View {
        Picker("类型", selection: $transactionType) {
            Text("支出").tag(TransactionType.expense)
            Text("收入").tag(TransactionType.income)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color(.systemGroupedBackground))
        .onChange(of: transactionType) { _, _ in
            Task { await loadData() }
        }
    }
    
    @ViewBuilder
    private func categoryRow(_ category: Category, isParent: Bool) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .fill(category.swiftUIColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                transactionCategoryIcon(category, size: 22)
            }

            Text(category.name)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 编辑按钮
            Button {
                editingCategory = category
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 16))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 44, height: 44)
            }

            // 预设分类不可删除
            if !category.isDefault {
                // 删除按钮
                Button {
                    categoryToDelete = category
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    
    private func confirmDelete(_ category: Category) {
        Task {
            do {
                try await repository.deleteCategory(category)
                await loadData()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 清理导入时自动创建的非预设分类
    private func cleanupImportedCategories() async {
        do {
            let result = try await repository.cleanupImportedCategories()
            cleanupResult = result
            await loadData()
        } catch {
            errorMessage = "清理失败：\(error.localizedDescription)"
        }
    }
    
    @MainActor
    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            topLevelCategories = try await repository.getTopLevelCategories(by: transactionType)
            var map: [UUID: [Category]] = [:]
            for parent in topLevelCategories {
                map[parent.id] = try await repository.getSubCategories(parentId: parent.id)
            }
            subCategoriesMap = map
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Add Category Sheet

/// 新增分类步骤
enum AddCategoryStep: Int, CaseIterable {
    case selectParent = 1
    case selectOrCreate = 2
    case inputDetails = 3

    var title: String {
        switch self {
        case .selectParent: return "选择分类"
        case .selectOrCreate: return "选择子分类"
        case .inputDetails: return "填写详情"
        }
    }
}

/// 新增分类 Sheet
struct AddCategorySheet: View {
    @Environment(\.dismiss) var dismiss
    private let repository = FinanceRepository.shared
    private static let logger = Logger(subsystem: "com.holo.app", category: "AddCategorySheet")

    let parentId: UUID?
    let type: TransactionType
    let onSave: () -> Void

    // 步骤状态
    @State private var step: AddCategoryStep = .selectParent
    @State private var selectedParent: Category?

    // 详情输入状态
    @State private var name = ""
    @State private var iconName = presetCategoryIcons.first ?? "icon_dining"
    @State private var selectedColorHex = "#13A4EC"

    // 数据加载状态
    @State private var topLevelCategories: [Category] = []
    @State private var subCategories: [Category] = []
    @State private var isSaving = false

    private let presetColors = ["#13A4EC", "#10B981", "#F97316", "#EC4899", "#6366F1", "#64748B"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 步骤指示器
                stepIndicator

                Divider()

                // 步骤内容
                Group {
                    switch step {
                    case .selectParent:
                        step1SelectParentView
                    case .selectOrCreate:
                        step2SelectOrCreateView
                    case .inputDetails:
                        step3InputDetailsView
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
            .navigationTitle("新增分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .selectParent ? "取消" : "返回") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            goBack()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == .inputDetails {
                        Button("保存") {
                            saveCategory()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                    }
                }
            }
            .task {
                await loadTopLevelCategories()
            }
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(AddCategoryStep.allCases, id: \.self) { stepItem in
                HStack(spacing: 4) {
                    // 步骤圆圈
                    ZStack {
                        Circle()
                            .fill(stepCircleColor(for: stepItem))
                            .frame(width: 28, height: 28)

                        if stepItem.rawValue < step.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Text("\(stepItem.rawValue)")
                                .font(.system(size: 12, weight: stepItem == step ? .bold : .regular))
                                .foregroundColor(stepTextColor(for: stepItem))
                        }
                    }

                    // 连线（不在最后一个步骤）
                    if stepItem != AddCategoryStep.allCases.last {
                        Rectangle()
                            .fill(stepItem.rawValue < step.rawValue ? Color.holoPrimary : Color.holoBorder)
                            .frame(width: 20, height: 2)
                    }
                }
            }
        }
        .padding(.vertical, HoloSpacing.sm)
        .padding(.horizontal, HoloSpacing.lg)
        .background(Color.holoBackground)
    }

    private func stepCircleColor(for stepItem: AddCategoryStep) -> Color {
        if stepItem.rawValue < step.rawValue {
            return .holoPrimary
        } else if stepItem == step {
            return .holoPrimary.opacity(0.15)
        } else {
            return .holoBorder
        }
    }

    private func stepTextColor(for stepItem: AddCategoryStep) -> Color {
        if stepItem.rawValue < step.rawValue {
            return .white
        } else if stepItem == step {
            return .holoPrimary
        } else {
            return .holoTextSecondary
        }
    }

    // MARK: - Navigation

    private func goBack() {
        switch step {
        case .selectParent:
            dismiss()
        case .selectOrCreate:
            step = .selectParent
        case .inputDetails:
            if selectedParent != nil {
                step = .selectOrCreate
            } else {
                step = .selectParent
            }
        }
    }

    // MARK: - Data Loading

    private func loadTopLevelCategories() async {
        do {
            topLevelCategories = try await repository.getTopLevelCategories(by: type)
            if let pid = parentId {
                selectedParent = topLevelCategories.first { $0.id == pid }
            }
        } catch {
            Self.logger.error("加载一级分类失败：\(error.localizedDescription)")
        }
    }

    private func loadSubCategories(for parent: Category) async {
        do {
            subCategories = try await repository.getSubCategories(parentId: parent.id)
        } catch {
            Self.logger.error("加载二级分类失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Step 1: Select Parent

    private var step1SelectParentView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                Text("请选择一级分类")
                    .font(.headline)
                    .foregroundColor(.holoTextPrimary)
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.sm)

                // 一级分类网格
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                    ForEach(topLevelCategories, id: \.id) { category in
                        categorySelectionCell(category)
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)

                // 无（创建一级分类）选项
                createTopLevelOption
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.bottom, HoloSpacing.lg)
            }
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoBackground)
    }

    @ViewBuilder
    private func categorySelectionCell(_ category: Category) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(category.swiftUIColor.opacity(0.15))
                    .frame(width: 56, height: 56)

                transactionCategoryIcon(category, size: 28)
                    .foregroundColor(category.swiftUIColor)
            }

            Text(category.name)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedParent = category
            Task {
                await loadSubCategories(for: category)
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .selectOrCreate
                }
            }
        }
    }

    private var createTopLevelOption: some View {
        Button {
            selectedParent = nil
            subCategories = []
            withAnimation(.easeInOut(duration: 0.2)) {
                step = .inputDetails
            }
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.holoPrimary)

                Text("创建一级分类")
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)

                Spacer()
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .background(Color.holoCardBackground)
            .cornerRadius(12)
        }
    }

    // MARK: - Step 2: Select or Create SubCategory

    private var step2SelectOrCreateView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                // 一级分类信息
                if let parent = selectedParent {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(parent.swiftUIColor.opacity(0.15))
                                .frame(width: 40, height: 40)
                            transactionCategoryIcon(parent, size: 20)
                                .foregroundColor(parent.swiftUIColor)
                        }
                        Text(parent.name)
                            .font(.headline)
                            .foregroundColor(.holoTextPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.sm)
                }

                Text("选择已有二级分类或创建新分类")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, HoloSpacing.lg)

                // 二级分类列表
                if subCategories.isEmpty {
                    Text("暂无二级分类")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPlaceholder)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HoloSpacing.xl)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                        ForEach(subCategories, id: \.id) { category in
                            subCategoryCell(category)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                }

                // 新增二级分类按钮
                createSubCategoryOption
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.bottom, HoloSpacing.lg)
            }
            .padding(.vertical, HoloSpacing.md)
        }
        .background(Color.holoBackground)
    }

    @ViewBuilder
    private func subCategoryCell(_ category: Category) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(category.swiftUIColor.opacity(0.15))
                    .frame(width: 56, height: 56)

                transactionCategoryIcon(category, size: 28)
                    .foregroundColor(category.swiftUIColor)
            }

            Text(category.name)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 选择已有二级分类，直接关闭
            onSave()
            dismiss()
        }
    }

    private var createSubCategoryOption: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                step = .inputDetails
            }
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.holoPrimary)

                Text("创建二级分类")
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)

                Spacer()
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .background(Color.holoCardBackground)
            .cornerRadius(12)
        }
    }

    // MARK: - Step 3: Input Details

    private var step3InputDetailsView: some View {
        Form {
            Section("分类名称") {
                TextField("请输入名称", text: $name)
            }

            if let parent = selectedParent {
                Section("所属一级分类") {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(parent.swiftUIColor.opacity(0.15))
                                .frame(width: 32, height: 32)
                            transactionCategoryIcon(parent, size: 16)
                                .foregroundColor(parent.swiftUIColor)
                        }
                        Text(parent.name)
                            .foregroundColor(.holoTextPrimary)
                    }
                }
            }

            Section("图标") {
                IconPickerGrid(selectedIcon: $iconName)
                    .padding(.vertical, 8)
            }

            Section("颜色") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(presetColors, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Circle()
                                    .strokeBorder(selectedColorHex == hex ? Color.primary : .clear, lineWidth: 2)
                            )
                            .onTapGesture { selectedColorHex = hex }
                    }
                }
            }
        }
        .background(Color.holoBackground)
    }

    // MARK: - Save

    private func saveCategory() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let effectiveParentId = selectedParent?.id ?? parentId
        isSaving = true
        Task {
            do {
                _ = try await repository.addCategory(
                    name: trimmed,
                    icon: iconName,
                    color: selectedColorHex,
                    type: type,
                    isDefault: false,
                    parentId: effectiveParentId
                )
                onSave()
                dismiss()
            } catch {
                Self.logger.error("保存分类失败：\(error.localizedDescription)")
            }
            isSaving = false
        }
    }
}

// MARK: - Edit Category Sheet

/// 编辑分类 Sheet（仅支持改名称与图标，预设可编辑）
struct EditCategorySheet: View {
    @Environment(\.dismiss) var dismiss
    private let repository = FinanceRepository.shared
    private static let logger = Logger(subsystem: "com.holo.app", category: "EditCategorySheet")

    let category: Category
    let onSave: () -> Void
    
    @State private var name: String = ""
    @State private var iconName: String = ""
    @State private var isSaving = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("分类名称") {
                    TextField("名称", text: $name)
                }
                Section("图标") {
                    IconPickerGrid(selectedIcon: $iconName)
                        .padding(.vertical, 8)
                }
            }
            .navigationTitle("编辑分类")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                name = category.name
                iconName = category.icon
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveChanges()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }
    
    private func saveChanges() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        Task {
            do {
                var updates = CategoryUpdates()
                updates.name = trimmed
                updates.icon = iconName
                try await repository.updateCategory(category, updates: updates)
                onSave()
                dismiss()
            } catch {
                Self.logger.error("更新分类失败：\(error.localizedDescription)")
            }
            isSaving = false
        }
    }
}

// MARK: - Category Identifiable

extension Category: @retroactive Identifiable {}
