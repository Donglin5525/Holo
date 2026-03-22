//
//  TagListView.swift
//  Holo
//
//  标签列表视图
//  展示所有标签，支持按标签筛选任务
//

import SwiftUI

/// 标签列表视图
struct TagListView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    @ObservedObject var repository: TodoRepository

    // MARK: - State

    /// 当前选中的标签
    @State private var selectedTag: TodoTag?

    /// 选中标签关联的任务
    @State private var tasksForSelectedTag: [TodoTask] = []

    /// 选中的任务（用于 sheet 展示）
    private struct TaskSelection: Identifiable, Equatable {
        let id: UUID
    }
    @State private var selectedTask: TaskSelection?

    // MARK: - Body

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 标签区域
                tagSection

                Divider()
                    .padding(.vertical, HoloSpacing.sm)

                // 关联任务区域
                if let tag = selectedTag {
                    taskSection(for: tag)
                } else {
                    emptySelectionView
                }
            }
            .background(Color.holoBackground)
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .onChange(of: selectedTag) { _, newTag in
            if let tag = newTag {
                tasksForSelectedTag = repository.getTasks(tag: tag)
            } else {
                tasksForSelectedTag = []
            }
        }
        .sheet(item: $selectedTask) { selection in
            if let task = tasksForSelectedTag.first(where: { $0.id == selection.id }) {
                TaskDetailView(repository: repository, task: task)
            } else if let task = repository.findTask(by: selection.id) {
                TaskDetailView(repository: repository, task: task)
            } else {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Tag Section

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("全部标签")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                Text("\(repository.tags.count)")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.md)

            if repository.tags.isEmpty {
                emptyTagView
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    FlowLayout(spacing: HoloSpacing.sm) {
                        ForEach(repository.tags, id: \.id) { tag in
                            TagChip(
                                text: tag.name,
                                isSelected: selectedTag?.id == tag.id,
                                color: Color(hex: tag.color)
                            ) {
                                if selectedTag?.id == tag.id {
                                    selectedTag = nil
                                } else {
                                    selectedTag = tag
                                }
                            }
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.vertical, HoloSpacing.sm)
                }
            }
        }
    }

    private var emptyTagView: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "tag.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("暂无标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.lg)
    }

    // MARK: - Task Section

    private func taskSection(for tag: TodoTag) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 已选标签指示
            HStack {
                Text("已选：")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                TagChip(
                    text: tag.name,
                    isSelected: true,
                    color: Color(hex: tag.color)
                ) {
                    selectedTag = nil
                }

                Spacer()

                Text("\(tasksForSelectedTag.count) 条任务")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)

            Divider()

            if tasksForSelectedTag.isEmpty {
                emptyTaskView
            } else {
                ScrollView {
                    LazyVStack(spacing: HoloSpacing.sm) {
                        ForEach(tasksForSelectedTag, id: \.id) { task in
                            TaskCardView(task: task, repository: repository)
                                .onTapGesture {
                                    selectedTask = TaskSelection(id: task.id)
                                }
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.vertical, HoloSpacing.md)
                }
            }
        }
    }

    private var emptyTaskView: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text("该标签下暂无任务")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var emptySelectionView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "tag")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.3))

            Text("点击标签筛选任务")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    TagListView(repository: TodoRepository.shared)
}
