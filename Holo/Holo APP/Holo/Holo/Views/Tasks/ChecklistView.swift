//
//  ChecklistView.swift
//  Holo
//
//  检查清单视图
//  统一 Holo 设计风格：卡片布局、Holo 颜色系统
//

import SwiftUI
import CoreData
import OSLog

struct ChecklistView: View {
    @ObservedObject var repository: TodoRepository
    @State var task: TodoTask
    @Environment(\.dismiss) var dismiss
    @State private var newCheckItemTitle = ""
    @State private var checkItems: [CheckItem] = []
    @State private var editingItemId: UUID?
    @State private var editingTitle = ""
    @FocusState private var isEditingFocused: Bool

    private static let logger = Logger(subsystem: "com.holo.app", category: "ChecklistView")

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: HoloSpacing.lg) {
                        // 进度概览卡片
                        if !checkItems.isEmpty {
                            progressCard
                        }

                        // 检查项列表
                        checkItemsList

                        // 添加检查项
                        addCheckItemCard
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                    .padding(.bottom, HoloSpacing.xl)
                }
            }
            .navigationTitle("检查清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
            .onAppear(perform: reloadCheckItems)
        }
    }

    // MARK: - 进度概览卡片

    private var progressCard: some View {
        VStack(spacing: HoloSpacing.sm) {
            HStack {
                Text("完成进度")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text(task.checkItemProgress)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            // 进度条
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.holoTextSecondary.opacity(0.15))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.holoPrimary)
                        .frame(width: geometry.size.width * task.checkItemProgressPercent)
                }
            }
            .frame(height: 6)
        }
        .padding()
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    // MARK: - 检查项列表

    private var checkItemsList: some View {
        VStack(spacing: 0) {
            if checkItems.isEmpty {
                // 空状态
                VStack(spacing: HoloSpacing.md) {
                    Image(systemName: "checklist")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.holoTextSecondary.opacity(0.5))

                    Text("暂无检查项")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)

                    Text("添加检查项来分解任务")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.xxl)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.lg)
            } else {
                ForEach(checkItems, id: \.id) { item in
                    checkItemRow(item)
                        .background(Color.holoCardBackground)

                    if item.id != checkItems.last?.id {
                        Divider()
                            .padding(.horizontal)
                    }
                }
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.lg)
            }
        }
    }

    // MARK: - 检查项行

    private func checkItemRow(_ item: CheckItem) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            // 勾选按钮
            Button {
                toggleCheckItem(item)
            } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(item.isChecked ? .holoSuccess : .holoTextSecondary.opacity(0.5))
            }
            .buttonStyle(PlainButtonStyle())

            // 标题（点击进入编辑）
            if editingItemId == item.id {
                TextField("检查项内容", text: $editingTitle)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .focused($isEditingFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        commitEdit(item: item)
                    }
                    .onChange(of: isEditingFocused) { _, focused in
                        if !focused {
                            commitEdit(item: item)
                        }
                    }
            } else {
                Text(item.title)
                    .font(.holoBody)
                    .foregroundColor(item.isChecked ? .holoTextSecondary : .holoTextPrimary)
                    .strikethrough(item.isChecked, color: .holoTextSecondary)
                    .onTapGesture {
                        startEditing(item: item)
                    }
            }

            Spacer()

            // 删除按钮
            Button {
                deleteCheckItem(item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoError.opacity(0.7))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal)
        .padding(.vertical, HoloSpacing.sm + 4)
    }

    // MARK: - 添加检查项卡片

    private var addCheckItemCard: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "plus.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.holoPrimary)

            TextField("添加检查项", text: $newCheckItemTitle)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .submitLabel(.done)
                .onSubmit {
                    addCheckItem()
                }

            Button {
                addCheckItem()
            } label: {
                Text("添加")
                    .font(.holoCaption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(newCheckItemTitle.trimmingCharacters(in: .whitespaces).isEmpty ? Color.holoTextSecondary.opacity(0.3) : Color.holoPrimary)
                    )
            }
            .disabled(newCheckItemTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    // MARK: - 操作方法

    private func toggleCheckItem(_ item: CheckItem) {
        do {
            try repository.toggleCheckItem(item)
        } catch {
            Self.logger.error("切换检查项失败：\(error.localizedDescription)")
        }
    }

    private func addCheckItem() {
        let trimmedTitle = newCheckItemTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        do {
            let order = Int16(checkItems.count)
            let item = try repository.addCheckItem(title: trimmedTitle, to: task, order: order)
            checkItems.append(item)
            newCheckItemTitle = ""
        } catch {
            Self.logger.error("添加检查项失败：\(error.localizedDescription)")
        }
    }

    private func deleteCheckItem(_ item: CheckItem) {
        let itemID = item.id
        if editingItemId == itemID { cancelEditing() }
        checkItems.removeAll { $0.id == itemID }

        do {
            try repository.deleteCheckItem(item)
        } catch {
            Self.logger.error("删除检查项失败：\(error.localizedDescription)")
            reloadCheckItems()
        }
    }

    private func startEditing(item: CheckItem) {
        editingItemId = item.id
        editingTitle = item.title
        isEditingFocused = true
    }

    private func commitEdit(item: CheckItem) {
        guard editingItemId == item.id else { return }
        let trimmed = editingTitle.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != item.title {
            do {
                try repository.updateCheckItemTitle(item, newTitle: trimmed)
                if let idx = checkItems.firstIndex(where: { $0.id == item.id }) {
                    checkItems[idx] = item
                }
            } catch {
                Self.logger.error("更新检查项标题失败：\(error.localizedDescription)")
            }
        }
        editingItemId = nil
        editingTitle = ""
    }

    private func cancelEditing() {
        editingItemId = nil
        editingTitle = ""
        isEditingFocused = false
    }

    private func reloadCheckItems() {
        let items = task.checkItems?.allObjects as? [CheckItem] ?? []
        checkItems = items.sorted { $0.order < $1.order }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ChecklistView(
            repository: TodoRepository.shared,
            task: createSampleTask()
        )
    }
}

private func createSampleTask() -> TodoTask {
    let context = CoreDataStack.shared.viewContext
    let task = TodoTask(context: context)
    task.id = UUID()
    task.title = "示例任务"
    task.createdAt = Date()
    task.updatedAt = Date()
    return task
}
