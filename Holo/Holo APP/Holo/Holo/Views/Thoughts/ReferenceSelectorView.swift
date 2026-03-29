//
//  ReferenceSelectorView.swift
//  Holo
//
//  观点模块 - 引用选择器
//  用于选择要引用的其他想法
//

import SwiftUI
import CoreData

// MARK: - ReferenceSelectorView

/// 引用选择器视图
struct ReferenceSelectorView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    @Binding var selectedIds: [UUID]

    /// 搜索文本
    @State private var searchText: String = ""

    /// 所有想法（排除已软删除）
    @State private var thoughts: [Thought] = []

    // MARK: - Computed Properties

    /// 筛选后的想法
    var filteredThoughts: [Thought] {
        if searchText.isEmpty {
            return thoughts
        }
        return thoughts.filter {
            $0.content.localizedCaseInsensitiveContains(searchText) ||
            $0.tagArray.contains { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 搜索栏
                searchBar

                // 已选数量
                if !selectedIds.isEmpty {
                    selectedCountBar
                }

                // 想法列表
                if filteredThoughts.isEmpty {
                    emptyStateView
                } else {
                    thoughtList
                }
            }
            .background(Color.holoBackground)
            .navigationTitle("选择引用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                loadThoughts()
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.holoTextSecondary)

            TextField("搜索想法...", text: $searchText)
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - Selected Count Bar

    private var selectedCountBar: some View {
        HStack {
            Text("已选择 \(selectedIds.count) 条想法")
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)

            Spacer()

            Button("清除") {
                selectedIds = []
                HapticManager.light()
            }
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.bottom, HoloSpacing.sm)
    }

    // MARK: - Thought List

    private var thoughtList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: HoloSpacing.sm) {
                ForEach(filteredThoughts) { thought in
                    ReferenceThoughtRow(
                        thought: thought,
                        isSelected: selectedIds.contains(thought.id)
                    ) {
                        toggleSelection(thought.id)
                    }
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无可引用的想法")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text("先记录一些想法再来引用吧")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    /// 加载想法
    private func loadThoughts() {
        let context = CoreDataStack.shared.viewContext
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "isSoftDeleted == NO")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = 100

        do {
            thoughts = try context.fetch(request)
        } catch {
            print("[ReferenceSelectorView] 加载想法失败: \(error)")
            thoughts = []
        }
    }

    /// 切换选中状态
    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.removeAll { $0 == id }
        } else {
            selectedIds.append(id)
        }
        HapticManager.light()
    }
}

// MARK: - Reference Thought Row

/// 引用想法行组件
struct ReferenceThoughtRow: View {
    let thought: Thought
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.sm) {
                // 选中指示器
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 4) {
                    // 心情和日期
                    HStack(spacing: 6) {
                        if let moodType = thought.moodType {
                            Text(moodType.emoji)
                                .font(.system(size: 12))
                        }
                        Text(thought.formattedDate)
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                    }

                    // 预览文本
                    Text(thought.previewText)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(2)
                }

                Spacer()
            }
            .padding(HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(isSelected ? Color.holoPrimary.opacity(0.1) : Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(isSelected ? Color.holoPrimary : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ReferenceSelectorView(selectedIds: .constant([]))
}