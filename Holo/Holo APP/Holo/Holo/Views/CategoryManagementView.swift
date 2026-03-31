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
    @State private var addCategoryParentId: UUID?
    @State private var editingCategory: Category?
    @State private var categoryToDelete: Category?
    @State private var showDeleteConfirmation = false
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
                        NavigationLink {
                            subCategoryList(for: parent)
                        } label: {
                            topLevelCategoryRow(parent)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 88)
                }
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
                    // 新增一级分类按钮
                    Button {
                        addCategoryParentId = nil
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
            AddCategorySheet(parentId: addCategoryParentId, type: transactionType) {
                Task { await loadData() }
            }
        }
        .sheet(item: $editingCategory) { category in
            EditCategorySheet(category: category) {
                Task { await loadData() }
            }
        }
        .onChange(of: editingCategory) { _, _ in
            categoryToDelete = nil
            showDeleteConfirmation = false
        }
        .onChange(of: showAddCategory) { _, newValue in
            if newValue {
                categoryToDelete = nil
                showDeleteConfirmation = false
            }
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("确认删除", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let cat = categoryToDelete {
                    confirmDelete(cat)
                }
                categoryToDelete = nil
                showDeleteConfirmation = false
            }
            Button("取消", role: .cancel) {
                categoryToDelete = nil
                showDeleteConfirmation = false
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
    
    private func topLevelCategoryRow(_ category: Category) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .fill(category.swiftUIColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                transactionCategoryIcon(category, size: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Text("\(subCategoriesMap[category.id]?.count ?? 0) 个子分类")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func categoryRow(_ category: Category) -> some View {
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
            .buttonStyle(.borderless)

            // 预设分类不可删除
            if !category.isDefault {
                Button {
                    Self.logger.info("🗑️ 删除按钮触发: \(category.name)")
                    categoryToDelete = category
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func subCategoryList(for parent: Category) -> some View {
        let subs = subCategoriesMap[parent.id] ?? []
        return Group {
            if subs.isEmpty {
                VStack(spacing: HoloSpacing.md) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.holoTextPlaceholder)
                    Text("暂无二级分类")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPlaceholder)
                    Text("点击右上角 + 添加")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(subs, id: \.id) { child in
                        categoryRow(child)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(parent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: HoloSpacing.sm) {
                    // 编辑一级分类
                    Button {
                        editingCategory = parent
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 18))
                            .foregroundColor(.holoPrimary)
                    }
                    // 新增二级分类
                    Button {
                        addCategoryParentId = parent.id
                        showAddCategory = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
        }
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

/// 新增分类 Sheet
struct AddCategorySheet: View {
    @Environment(\.dismiss) var dismiss
    private let repository = FinanceRepository.shared
    private static let logger = Logger(subsystem: "com.holo.app", category: "AddCategorySheet")

    let parentId: UUID?
    let type: TransactionType
    let onSave: () -> Void

    @State private var name = ""
    @State private var iconName = presetCategoryIcons.first ?? "icon_dining"
    @State private var selectedColorHex = "#13A4EC"
    @State private var parentCategory: Category?
    @State private var isSaving = false
    @State private var showDismissAlert: Bool = false

    private let presetColors = ["#13A4EC", "#10B981", "#F97316", "#EC4899", "#6366F1", "#64748B"]

    var body: some View {
        NavigationStack {
            Form {
                if let parent = parentCategory {
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

                Section("分类名称") {
                    TextField("请输入名称", text: $name)
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
            .navigationTitle(parentId != nil ? "新增二级分类" : "新增一级分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                            showDismissAlert = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveCategory()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .task {
                if let pid = parentId {
                    do {
                        let categories = try await repository.getTopLevelCategories(by: type)
                        parentCategory = categories.first { $0.id == pid }
                    } catch {
                        Self.logger.error("加载一级分类失败：\(error.localizedDescription)")
                    }
                }
            }
            .unsavedChangesAlert(isPresented: $showDismissAlert) {
                dismiss()
            }
        }
    }

    private func saveCategory() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        Task {
            do {
                _ = try await repository.addCategory(
                    name: trimmed,
                    icon: iconName,
                    color: selectedColorHex,
                    type: type,
                    isDefault: false,
                    parentId: parentId
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
    @State private var showDismissAlert: Bool = false
    
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
                    Button("取消") {
                        if name != category.name || iconName != category.icon {
                            showDismissAlert = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveChanges()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
        .unsavedChangesAlert(isPresented: $showDismissAlert) {
            dismiss()
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
