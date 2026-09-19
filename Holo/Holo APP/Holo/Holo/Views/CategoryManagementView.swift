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

    /// 以弹层（sheet）方式打开时显示「完成」关闭按钮；被 push 进入时保持系统返回
    var showsDoneButton: Bool = false
    
    @State private var transactionType: TransactionType = .expense
    @State private var topLevelCategories: [Category] = []
    @State private var subCategoriesMap: [UUID: [Category]] = [:]
    @State private var showAddCategory = false
    @State private var addCategoryParentId: UUID?
    @State private var editingCategory: Category?
    @State private var categoryToDelete: Category?
    @State private var showDeleteConfirmation = false
    /// 删除影响预检快照（纯值，弹层与执行都不持有可失效的托管对象）
    @State private var deletionSnapshot: CategoryDeletionImpactSnapshot?
    @State private var showDeletionImpact = false
    /// 被删分类的展示快照（删除执行后源对象失效，弹层渲染只读这些值）
    @State private var deleteDisplayName = ""
    @State private var deleteDisplayIcon = ""
    @State private var deleteDisplayColor = Color.holoPrimary
    @State private var deleteDisplayType = TransactionType.expense
    /// 简单确认页的说明文案（无引用分类）
    @State private var deleteConfirmSummary = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    
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
                    // 新增一级分类按钮（右上角只保留新增；删除从具体分类行侧滑发起，
                    // 清理导入分类入口已挪至「设置 → 数据管理」）
                    Button {
                        openAddTopLevelCategory()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
            // 「完成」是主动作，放在导航栏最右（声明顺序决定同侧多个按钮的左右排列）
            if showsDoneButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
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
        // 有引用分类的影响处理页：二级走明细去向页，一级走子分类去向页（纯值快照）
        .sheet(isPresented: $showDeletionImpact) {
            if let snapshot = deletionSnapshot {
                if snapshot.isSecondary {
                    CategoryDeletionImpactView(
                        snapshot: snapshot,
                        sourceName: deleteDisplayName,
                        sourceIcon: deleteDisplayIcon,
                        sourceColor: deleteDisplayColor,
                        sourceType: deleteDisplayType
                    ) {
                        HoloToastCenter.shared.show(String(localized: "已删除，30 天内可从最近删除恢复"), type: .success)
                        categoryToDelete = nil
                        deletionSnapshot = nil
                        Task { await loadData() }
                    }
                } else {
                    PrimaryCategoryDispositionView(
                        snapshot: snapshot,
                        sourceName: deleteDisplayName,
                        sourceIcon: deleteDisplayIcon,
                        sourceColor: deleteDisplayColor,
                        sourceType: deleteDisplayType
                    ) {
                        HoloToastCenter.shared.show(String(localized: "已删除，30 天内可从最近删除恢复"), type: .success)
                        categoryToDelete = nil
                        deletionSnapshot = nil
                        Task { await loadData() }
                    }
                }
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
        .alert(String(localized: "删除「\(deleteDisplayName)」"), isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {
                categoryToDelete = nil
                deletionSnapshot = nil
            }
            Button("删除", role: .destructive) {
                confirmSimpleDelete()
            }
        } message: {
            Text(deleteConfirmSummary.isEmpty
                ? String(localized: "删除后 30 天内可在最近删除中恢复。")
                : deleteConfirmSummary)
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
                    if !parent.isSystem {
                        Button(role: .destructive) {
                            Task { await prepareDelete(parent) }
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
                    title: String(localized: "新增一级分类"),
                    subtitle: String(localized: "创建新的一级科目分组")
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
        .accessibilityLabel(String(localized: "编辑\(category.name)"))
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
        // 删除确认弹窗统一挂在根页：本页曾重复挂载同一 showDeleteConfirmation，
        // 双 alert 会触发双次执行（先成功后 notFound），造成「假成功」与错误弹窗
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
        .accessibilityLabel(String(localized: "新增第一个二级分类"))
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
                        if !child.isSystem {
                            Button(role: .destructive) {
                                Task { await prepareDelete(child) }
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
                    title: String(localized: "在「\(parent.name)」下新增二级分类"),
                    subtitle: String(localized: "会自动归属到当前一级分类")
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
    
    /// 删除入口：先跑统一预检（引用全景 + 版本指纹），再按引用情况分流——
    /// 无引用走简单确认，有引用走影响处理页（方案 §3）
    private func prepareDelete(_ category: Category) async {
        do {
            let snapshot = try await repository.categoryDeletionImpact(categoryID: category.id)
            categoryToDelete = category
            deletionSnapshot = snapshot
            // ⚠️ 趁对象仍有效先把展示内容拷成值快照，删除执行后源对象会失效
            deleteDisplayName = category.name
            deleteDisplayIcon = category.icon
            deleteDisplayColor = category.swiftUIColor
            deleteDisplayType = category.transactionType
            if snapshot.requiresImpactFlow {
                showDeletionImpact = true
            } else {
                if snapshot.scope == .primary, !snapshot.childCategories.isEmpty {
                    deleteConfirmSummary = String(localized: "将同时删除 \(snapshot.childCategories.count) 个空子分类。删除后 30 天内可在最近删除中恢复。")
                } else {
                    deleteConfirmSummary = ""
                }
                showDeleteConfirmation = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 无引用分类的简单确认：直接软删除进回收站（空子分类分组逐个入批）
    private func confirmSimpleDelete() {
        guard let snapshot = deletionSnapshot else {
            categoryToDelete = nil
            return
        }
        let disposition: CategoryDeletionDisposition
        if snapshot.isSecondary {
            disposition = .secondary(.deleteWithReferences)
        } else {
            let dispositions = Dictionary(
                uniqueKeysWithValues: snapshot.childCategories.map {
                    ($0.id, SecondaryCategoryDisposition.deleteWithReferences)
                }
            )
            disposition = .primary(.disposeChildren(dispositions))
        }
        performDelete(disposition: disposition)
    }

    /// 统一执行入口：ID + 值指令 + 版本指纹，不跨弹层持有托管对象。
    /// 本地列表只在执行成功后才移除——失败时保持数据可见，避免「假成功」
    /// （曾实证：先移除后失败，用户以为删掉了，冷启动数据又回来）。
    private func performDelete(disposition: CategoryDeletionDisposition) {
        guard let snapshot = deletionSnapshot else { return }
        let command = CategoryDeletionCommand(
            sourceCategoryID: snapshot.sourceCategoryID,
            expectedRevision: snapshot.sourceRevision,
            disposition: disposition
        )
        Task {
            do {
                try await repository.executeCategoryDeletion(command)
                if let category = categoryToDelete {
                    topLevelCategories.removeAll { $0.id == category.id }
                    if category.isTopLevel {
                        subCategoriesMap.removeValue(forKey: category.id)
                    } else if let parentId = category.parentId {
                        subCategoriesMap[parentId]?.removeAll { $0.id == category.id }
                    }
                }
                HoloToastCenter.shared.show(String(localized: "已删除，30 天内可从最近删除恢复"), type: .success)
            } catch {
                Self.logger.error("分类删除执行失败 id=\(snapshot.sourceCategoryID, privacy: .public)：\(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
            categoryToDelete = nil
            deletionSnapshot = nil
            await loadData()
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
            .navigationTitle(parentId != nil ? String(localized: "新增二级分类") : String(localized: "新增一级分类"))
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
