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
                Button("清除所有映射", role: .destructive) {
                    showClearAllConfirmation = true
                }
            } footer: {
                Text("共 \(mappings.count) 条映射")
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
