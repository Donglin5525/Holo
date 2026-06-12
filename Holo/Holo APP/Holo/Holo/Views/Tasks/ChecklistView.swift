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
    @State private var displayedProgress: Double = 0
    @State private var showCompletionCelebration = false
    @State private var completionCelebrationID = UUID()

    private static let logger = Logger(subsystem: "com.holo.app", category: "ChecklistView")

    /// 从本地数组计算进度，确保和 UI 显示的勾选状态一致
    private var localProgress: Double {
        guard !checkItems.isEmpty else { return 0 }
        let completed = checkItems.filter { $0.isChecked }.count
        return Double(completed) / Double(checkItems.count)
    }

    private var localProgressText: String {
        let completed = checkItems.filter { $0.isChecked }.count
        return "\(completed)/\(checkItems.count)"
    }

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

                        // 子任务列表
                        checkItemsList

                        // 添加子任务
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
            .onAppear {
                reloadCheckItems()
                displayedProgress = localProgress
            }
        }
    }

    // MARK: - 进度概览卡片

    private var progressCard: some View {
        let progress = min(max(displayedProgress, 0), 1)
        let isComplete = localProgress >= 1.0

        return VStack(spacing: HoloSpacing.sm) {
            HStack {
                Text("完成进度")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Text(localProgressText)
                    .font(.holoCaption)
                    .foregroundColor(isComplete ? .holoSuccess : .holoTextSecondary)
                    .contentTransition(.numericText())
            }

            ChecklistProgressBar(progress: progress, isComplete: isComplete)
        }
        .padding()
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
        .overlay {
            if showCompletionCelebration {
                CompletionCelebrationView {
                    showCompletionCelebration = false
                }
                .id(completionCelebrationID)
                .frame(height: 110)
                .offset(y: -18)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 子任务列表

    private var checkItemsList: some View {
        VStack(spacing: 0) {
            if checkItems.isEmpty {
                // 空状态
                VStack(spacing: HoloSpacing.md) {
                    Image(systemName: "checklist")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.holoTextSecondary.opacity(0.5))

                    Text("暂无子任务")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)

                    Text("添加子任务来分解任务")
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

    // MARK: - 子任务行

    private func checkItemRow(_ item: CheckItem) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            // 勾选按钮
            Button {
                toggleCheckItem(item)
            } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(item.isChecked ? .holoSuccess : .holoTextSecondary.opacity(0.5))
                    .symbolEffect(.bounce, value: item.isChecked)
            }
            .buttonStyle(PlainButtonStyle())

            // 标题（点击进入编辑）
            if editingItemId == item.id {
                TextField("子任务内容", text: $editingTitle)
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

    // MARK: - 添加子任务卡片

    private var addCheckItemCard: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "plus.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.holoPrimary)

            TextField("添加子任务", text: $newCheckItemTitle)
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
        let progressBeforeChange = localProgress
        displayedProgress = progressBeforeChange

        do {
            try repository.toggleCheckItem(item)
            reloadCheckItems()
            applyProgressChange(from: progressBeforeChange, to: localProgress)
        } catch {
            Self.logger.error("切换子任务失败：\(error.localizedDescription)")
        }
    }

    private func addCheckItem() {
        let trimmedTitle = newCheckItemTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        do {
            let progressBeforeChange = localProgress
            let order = Int16(checkItems.count)
            let item = try repository.addCheckItem(title: trimmedTitle, to: task, order: order)
            displayedProgress = progressBeforeChange
            checkItems.append(item)
            applyProgressChange(from: progressBeforeChange, to: localProgress)
            newCheckItemTitle = ""
        } catch {
            Self.logger.error("添加子任务失败：\(error.localizedDescription)")
        }
    }

    private func deleteCheckItem(_ item: CheckItem) {
        let itemID = item.id
        if editingItemId == itemID { cancelEditing() }
        let progressBeforeChange = localProgress

        do {
            try repository.deleteCheckItem(item)
            checkItems.removeAll { $0.id == itemID }
            applyProgressChange(from: progressBeforeChange, to: localProgress)
        } catch {
            Self.logger.error("删除子任务失败：\(error.localizedDescription)")
            reloadCheckItems()
            applyProgressChange(to: localProgress)
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
                Self.logger.error("更新子任务标题失败：\(error.localizedDescription)")
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

    private func applyProgressChange(from previousProgress: Double? = nil, to nextProgress: Double) {
        let startProgress = previousProgress ?? displayedProgress
        let wasComplete = startProgress >= 1.0
        let targetProgress = min(max(nextProgress, 0), 1)

        displayedProgress = min(max(startProgress, 0), 1)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            withAnimation(.easeInOut(duration: 0.62)) {
                displayedProgress = targetProgress
            }
        }

        if !wasComplete && nextProgress >= 1.0 {
            triggerCompletionCelebration(after: 0.58)
        } else if nextProgress < 1.0 {
            showCompletionCelebration = false
        }
    }

    private func triggerCompletionCelebration(after delay: Double) {
        showCompletionCelebration = false
        completionCelebrationID = UUID()

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            showCompletionCelebration = true
        }
    }
}

// MARK: - ChecklistProgressBar

private struct ChecklistProgressBar: View {
    let progress: Double
    let isComplete: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.holoTextSecondary.opacity(0.12))

                RoundedRectangle(cornerRadius: 3)
                    .fill(isComplete ? Color.holoSuccess : Color.holoPrimary)
                    .frame(width: geometry.size.width * progress)
                    .shadow(color: (isComplete ? Color.holoSuccess : Color.holoPrimary).opacity(isComplete ? 0.25 : 0), radius: 5, x: 0, y: 0)
                    .animation(.easeInOut(duration: 0.62), value: progress)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - CompletionCelebrationView

/// 完成进度 100% 时的轻量彩带动画
private struct CompletionCelebrationView: View {
    let onComplete: () -> Void

    @State private var isActive = false
    @State private var ribbons: [Ribbon] = []
    @State private var sparkleScale: CGFloat = 0.5

    private struct Ribbon: Identifiable {
        let id = UUID()
        let x: CGFloat
        let y: CGFloat
        let rotation: Double
        let color: Color
        let width: CGFloat
        let height: CGFloat
        let delay: Double
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Circle()
                    .stroke(Color.holoSuccess.opacity(isActive ? 0 : 0.28), lineWidth: 2)
                    .frame(width: 34, height: 34)
                    .scaleEffect(sparkleScale)
                    .position(x: geometry.size.width / 2, y: 22)
                    .animation(.easeOut(duration: 0.5), value: sparkleScale)

                ForEach(ribbons) { ribbon in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ribbon.color)
                        .frame(width: ribbon.width, height: ribbon.height)
                        .rotationEffect(.degrees(isActive ? ribbon.rotation : ribbon.rotation * 0.2))
                        .position(x: geometry.size.width / 2, y: 24)
                        .offset(x: isActive ? ribbon.x : 0, y: isActive ? ribbon.y : 0)
                        .opacity(isActive ? 0 : 1)
                        .animation(.easeOut(duration: 1.05).delay(ribbon.delay), value: isActive)
                }
            }
        }
        .onAppear {
            generate()
            withAnimation(.easeOut(duration: 0.35)) {
                sparkleScale = 1.7
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                isActive = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                onComplete()
            }
        }
    }

    private func generate() {
        guard ribbons.isEmpty else { return }
        let palette: [Color] = [
            .holoPrimary,
            .holoSuccess,
            Color(red: 1.0, green: 0.68, blue: 0.38),
            Color(red: 0.42, green: 0.68, blue: 1.0),
        ]
        ribbons = (0..<22).map { index in
            let side = index.isMultiple(of: 2) ? -1.0 : 1.0
            return Ribbon(
                x: CGFloat(side * Double.random(in: 28...120)),
                y: CGFloat.random(in: -78...(-18)),
                rotation: Double.random(in: -170...170),
                color: palette[index % palette.count],
                width: CGFloat.random(in: 5...8),
                height: CGFloat.random(in: 14...24),
                delay: Double.random(in: 0...0.08)
            )
        }
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
