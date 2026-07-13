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
                categoryList
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
                        openAddTopLevelCategory()
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
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
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
            if let cat = categoryToDelete {
                let hasSubs = (subCategoriesMap[cat.id]?.count ?? 0) > 0
                Text(hasSubs
                    ? "删除后无法恢复。该分类及其 \(subCategoriesMap[cat.id]?.count ?? 0) 个子分类将被一并删除；若已被交易使用，将无法删除。"
                    : "删除后无法恢复；若该分类已被交易使用，将无法删除。")
            } else {
                Text("删除后无法恢复。")
            }
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
        .background(Color.holoBackground)
        .onChange(of: transactionType) { _, _ in
            Task { await loadData() }
        }
    }
    
    private func topLevelCategoryRow(_ category: Category) -> some View {
        HStack(spacing: HoloSpacing.md) {
            CategoryIconBadge(category: category, diameter: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Text("\(subCategoriesMap[category.id]?.count ?? 0) 个子分类")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            if !category.isSystem {
                editCategoryButton(category)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Category List

    private var categoryList: some View {
        List {
            ForEach(topLevelCategories, id: \.id) { parent in
                NavigationLink {
                    subCategoryList(for: parent)
                } label: {
                    topLevelCategoryRow(parent)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !parent.isSystem {
                        Button {
                            editingCategory = parent
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.holoPrimary)
                    }
                    if !parent.isDefault && !parent.isSystem {
                        Button(role: .destructive) {
                            categoryToDelete = parent
                            showDeleteConfirmation = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                openAddTopLevelCategory()
            } label: {
                addCategoryRow(
                    title: "新增一级分类",
                    subtitle: "创建新的一级科目分组"
                )
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.holoBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 88)
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: Category) -> some View {
        HStack(spacing: HoloSpacing.md) {
            CategoryIconBadge(category: category, diameter: 40)

            Text(category.name)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            if !category.isSystem {
                editCategoryButton(category)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !category.isSystem {
                editingCategory = category
            }
        }
    }

    private func addCategoryRow(title: String, subtitle: String) -> some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.holoPrimary.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoPrimary)
                Text(subtitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoTextPlaceholder)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func editCategoryButton(_ category: Category) -> some View {
        Button {
            editingCategory = category
        } label: {
            Image(systemName: "pencil.circle")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("编辑\(category.name)")
    }

    private func subCategoryList(for parent: Category) -> some View {
        let subs = subCategoriesMap[parent.id] ?? []
        return subCategoryContent(for: parent, subs: subs)
        .navigationTitle(parent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    openAddSubCategory(parent)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.holoPrimary)
                }
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
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
    }

    @ViewBuilder
    private func subCategoryContent(for parent: Category, subs: [Category]) -> some View {
        if subs.isEmpty {
            emptySubCategoryView(for: parent)
        } else {
            subCategoryRowsList(for: parent, subs: subs)
        }
    }

    private func emptySubCategoryView(for parent: Category) -> some View {
        VStack(spacing: HoloSpacing.md) {
            Spacer()
            Button {
                openAddSubCategory(parent)
            } label: {
                emptySubCategoryAddCard(parentName: parent.name)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, HoloSpacing.lg)
            Spacer()
        }
    }

    private func emptySubCategoryAddCard(parentName: String) -> some View {
        VStack(spacing: HoloSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.holoPrimary.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "plus")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            }

            Text("新增第一个二级分类")
                .font(.holoBody.bold())
                .foregroundColor(.holoPrimary)

            Text("会创建在「\(parentName)」这个一级科目下")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.xl)
        .padding(.horizontal, HoloSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoPrimary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoPrimary.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("新增第一个二级分类")
    }

    private func subCategoryRowsList(for parent: Category, subs: [Category]) -> some View {
        List {
            ForEach(subs, id: \.id) { child in
                categoryRow(child)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !child.isSystem {
                            Button {
                                editingCategory = child
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.holoPrimary)
                        }
                        if !child.isDefault && !child.isSystem {
                            Button(role: .destructive) {
                                categoryToDelete = child
                                showDeleteConfirmation = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
            }

            Button {
                openAddSubCategory(parent)
            } label: {
                addCategoryRow(
                    title: "在「\(parent.name)」下新增二级分类",
                    subtitle: "会自动归属到当前一级分类"
                )
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.holoBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 88)
        }
    }

    private func openAddTopLevelCategory() {
        addCategoryParentId = nil
        showAddCategory = true
    }

    private func openAddSubCategory(_ parent: Category) {
        addCategoryParentId = parent.id
        showAddCategory = true
    }
    
    private func confirmDelete(_ category: Category) {
        // 防御：对象已被删除则跳过
        guard !category.isDeleted else {
            categoryToDelete = nil
            showDeleteConfirmation = false
            return
        }
        // ⚠️ 先从本地数据中移除，避免 context.save() 后 SwiftUI 渲染已删除的 NSManagedObject
        // EXC_BREAKPOINT 根因：context.save() 将对象从 store 删除，但数组仍持有引用
        topLevelCategories.removeAll { $0.objectID == category.objectID }
        if category.isTopLevel {
            subCategoriesMap.removeValue(forKey: category.id)
        } else if let parentId = category.parentId {
            subCategoriesMap[parentId]?.removeAll { $0.objectID == category.objectID }
        }
        Task {
            do {
                try await repository.deleteCategory(category)
            } catch {
                errorMessage = error.localizedDescription
            }
            categoryToDelete = nil
            await loadData()
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
                .filter { !$0.isDeleted }
            var map: [UUID: [Category]] = [:]
            for parent in topLevelCategories {
                map[parent.id] = try await repository.getSubCategories(parentId: parent.id)
                    .filter { !$0.isDeleted }
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
    @State private var iconName = CategoryIconCatalog.allIcons.first ?? "tag.fill"
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
                            CategoryIconBadge(category: parent, diameter: 32)
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
                                .fill(Color(hex: hex))
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
            .scrollContentBackground(.hidden)
            .background(Color.holoBackground)
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
    @State private var defaultIconName: String?
    @State private var isSaving = false
    @State private var showDismissAlert: Bool = false

    private var canRestoreDefaultIcon: Bool {
        guard let defaultIconName else { return false }
        return iconName != defaultIconName
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("分类名称") {
                    TextField("名称", text: $name)
                }
                Section("图标") {
                    HStack(spacing: HoloSpacing.md) {
                        CategoryIconBadge(iconName: iconName, color: category.swiftUIColor, diameter: 44)

                        Text("当前图标")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer()

                        if canRestoreDefaultIcon {
                            Button("恢复默认") {
                                if let defaultIconName {
                                    iconName = defaultIconName
                                }
                            }
                            .font(.holoCaption)
                            .buttonStyle(.borderless)
                        }
                    }

                    IconPickerGrid(selectedIcon: $iconName)
                        .padding(.vertical, 8)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.holoBackground)
            .navigationTitle("编辑分类")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                name = category.name
                iconName = category.icon
            }
            .task {
                await loadDefaultIconName()
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

    @MainActor
    private func loadDefaultIconName() async {
        var parentName: String?
        if let parentId = category.parentId {
            do {
                parentName = try await repository.getAllCategories()
                    .first { $0.id == parentId }?
                    .name
            } catch {
                Self.logger.error("加载父分类失败：\(error.localizedDescription)")
            }
        }

        defaultIconName = Category.defaultIconName(
            name: category.name,
            type: category.transactionType,
            parentName: parentName
        )
    }
}

// MARK: - Category Identifiable

extension Category: Identifiable {}
