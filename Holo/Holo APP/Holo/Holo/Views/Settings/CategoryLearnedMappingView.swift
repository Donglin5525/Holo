//
//  CategoryLearnedMappingView.swift
//  Holo
//
//  分类学习映射管理
//  查看和删除 AI 自动学习的分类映射规则
//

import SwiftUI

struct CategoryLearnedMappingView: View {

    @State private var mappings: [CategoryLearnedMapping.LearnedMappingEntry] = []
    @State private var showClearAllConfirmation = false
    @State private var searchText = ""
    @State private var showRebuildConfirmation = false
    @State private var isRebuilding = false
    @State private var rebuildResult: Int?
    @State private var showRebuildResult = false

    private var filteredMappings: [CategoryLearnedMapping.LearnedMappingEntry] {
        let query = searchText.lowercased()
        let filtered = query.isEmpty
            ? mappings
            : mappings.filter { entry in
                entry.candidate.lowercased().contains(query)
                    || entry.targetPrimary.lowercased().contains(query)
                    || entry.targetSub.lowercased().contains(query)
                    || entry.primaryCategory.lowercased().contains(query)
            }
        return filtered
    }

    private var expenseMappings: [CategoryLearnedMapping.LearnedMappingEntry] {
        filteredMappings.filter { $0.type == .expense }
    }

    private var incomeMappings: [CategoryLearnedMapping.LearnedMappingEntry] {
        filteredMappings.filter { $0.type == .income }
    }

    var body: some View {
        Group {
            if mappings.isEmpty {
                emptyStateView
            } else if filteredMappings.isEmpty {
                noResultView
            } else {
                mappingList
            }
        }
        .navigationTitle("分类学习映射")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.holoBackground)
        .searchable(text: $searchText, prompt: "搜索分类映射")
        .onAppear { reload() }
        .confirmationDialog(
            "从交易记录重建映射？",
            isPresented: $showRebuildConfirmation,
            titleVisibility: .visible
        ) {
            Button("开始重建") { rebuildFromTransactions() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将扫描 AI 创建的交易，按「AI 原始猜测 → 你最终确认的分类」重建映射。已存在的映射不会被覆盖。")
        }
        .alert(
            isPresented: $showRebuildResult
        ) {
            Alert(
                title: Text(rebuildResult == 0 ? "没有找到可恢复的映射" : "重建完成"),
                message: Text(rebuildResultMessage)
            )
        }
    }

    // MARK: - Mapping List

    private var mappingList: some View {
        List {
            if !expenseMappings.isEmpty {
                Section("支出映射") {
                    ForEach(expenseMappings) { entry in
                        mappingRow(entry)
                    }
                    .onDelete { indexSet in
                        delete(at: indexSet, from: expenseMappings)
                    }
                }
            }

            if !incomeMappings.isEmpty {
                Section("收入映射") {
                    ForEach(incomeMappings) { entry in
                        mappingRow(entry)
                    }
                    .onDelete { indexSet in
                        delete(at: indexSet, from: incomeMappings)
                    }
                }
            }

            Section {
                if isRebuilding {
                    HStack {
                        ProgressView()
                        Text("正在扫描交易记录…")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                    }
                } else {
                    Button("从交易记录重建映射") {
                        showRebuildConfirmation = true
                    }
                }

                Button("清除所有映射", role: .destructive) {
                    showClearAllConfirmation = true
                }
            } footer: {
                Text("共 \(mappings.count) 条映射 · 已随 iCloud 同步")
                    .font(.caption)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .confirmationDialog(
            "确认清除所有 \(mappings.count) 条映射？",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除所有", role: .destructive) {
                CategoryLearnedMapping.removeAll()
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销，删除后 AI 将重新学习分类映射")
        }
    }

    private func mappingRow(_ entry: CategoryLearnedMapping.LearnedMappingEntry) -> some View {
        HStack {
            Text(displayCandidate(entry))
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)

            Text("\(entry.targetPrimary) / \(entry.targetSub)")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteEntry(entry)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: HoloSpacing.md) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.holoTextPlaceholder)

            Text("暂无学习映射")
                .font(.holoBody)
                .foregroundColor(.holoTextPlaceholder)

            Text("在 AI 对话中确认「待分类」交易的分类后\n系统会自动记录映射关系")
                .font(.system(size: 13))
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)

            Button {
                showRebuildConfirmation = true
            } label: {
                Label("从交易记录重建映射", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(isRebuilding)

            Spacer()
        }
    }

    private var noResultView: some View {
        VStack(spacing: HoloSpacing.md) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.holoTextPlaceholder)

            Text("未找到匹配结果")
                .font(.holoBody)
                .foregroundColor(.holoTextPlaceholder)

            Spacer()
        }
    }

    // MARK: - Helpers

    private var rebuildResultMessage: String {
        if let count = rebuildResult, count > 0 {
            return "已从 AI 创建的交易中恢复 \(count) 条分类映射。"
        }
        return "未找到 AI 创建且分类被你修改过的交易，无法重建。"
    }

    private func rebuildFromTransactions() {
        isRebuilding = true
        Task {
            let count = await CategoryLearnedMapping.rebuildFromTransactions()
            isRebuilding = false
            rebuildResult = count
            showRebuildResult = true
            reload()
        }
    }

    private func reload() {
        mappings = CategoryLearnedMapping.listAll()
    }

    private func deleteEntry(_ entry: CategoryLearnedMapping.LearnedMappingEntry) {
        CategoryLearnedMapping.removeByKey(entry.id)
        reload()
    }

    private func delete(
        at offsets: IndexSet,
        from source: [CategoryLearnedMapping.LearnedMappingEntry]
    ) {
        for index in offsets {
            CategoryLearnedMapping.removeByKey(source[index].id)
        }
        reload()
    }

    /// 展示候选分类名（空 primary 时只显示 candidate，否则显示 primary/candidate）
    private func displayCandidate(_ entry: CategoryLearnedMapping.LearnedMappingEntry) -> String {
        if entry.primaryCategory.isEmpty {
            return entry.candidate
        }
        return "\(entry.primaryCategory) / \(entry.candidate)"
    }
}
