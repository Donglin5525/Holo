//
//  CategoryManagementView.swift
//  Holo
//
//  分类管理页面
//  支持支出/收入 Tab、一级与二级分类展示、新增/编辑/删除（预设不可删）
//

import SwiftUI
import CoreData

/// 分类管理视图
struct CategoryManagementView: View {
    
    @Environment(\.dismiss) var dismiss
    private let repository = FinanceRepository.shared
    
    @State private var transactionType: TransactionType = .expense
    @State private var topLevelCategories: [Category] = []
    @State private var subCategoriesMap: [UUID: [Category]] = [:]
    @State private var showAddCategory = false
    @State private var editingCategory: Category?
    @State private var categoryToDelete: Category?
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddCategory = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.holoPrimary)
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
            .task {
                await loadData()
            }
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
            
            Button {
                editingCategory = category
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 16))
                    .foregroundColor(.holoPrimary)
            }
            
            // 预设分类不可删除
            if !category.isDefault {
                Button(role: .destructive) {
                    categoryToDelete = category
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                }
            }
        }
        .padding(.vertical, 4)
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
    
    let parentId: UUID?
    let type: TransactionType
    let onSave: () -> Void
    
    @State private var name = ""
    @State private var iconName = "tag.fill"
    @State private var selectedColorHex = "#13A4EC"
    @State private var selectedParentId: UUID?
    @State private var topLevelCategories: [Category] = []
    @State private var isSaving = false
    
    private let presetColors = ["#13A4EC", "#10B981", "#F97316", "#EC4899", "#6366F1", "#64748B"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section("分类名称") {
                    TextField("请输入名称", text: $name)
                }
                Section("所属一级分类（不选则为一级分类）") {
                    Picker("父分类", selection: $selectedParentId) {
                        Text("无（一级分类）").tag(nil as UUID?)
                        ForEach(topLevelCategories, id: \.id) { cat in
                            Text(cat.name).tag(cat.id as UUID?)
                        }
                    }
                }
                Section("图标") {
                    TextField("SF Symbol 或 icon_xxx", text: $iconName)
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
            .navigationTitle(selectedParentId == nil && parentId == nil ? "新增一级分类" : "新增子分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveCategory()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .task {
                do {
                    topLevelCategories = try await repository.getTopLevelCategories(by: type)
                    if let pid = parentId {
                        selectedParentId = pid
                    }
                } catch {
                    print("加载一级分类失败：\(error.localizedDescription)")
                }
            }
        }
    }
    
    private func saveCategory() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let effectiveParentId = selectedParentId ?? parentId
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
                print("保存分类失败：\(error.localizedDescription)")
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
                    TextField("图标", text: $iconName)
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
                print("更新分类失败：\(error.localizedDescription)")
            }
            isSaving = false
        }
    }
}

// MARK: - Category Identifiable

extension Category: @retroactive Identifiable {}
