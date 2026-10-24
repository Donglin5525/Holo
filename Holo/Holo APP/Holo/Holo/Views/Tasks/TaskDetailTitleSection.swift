//
//  TaskDetailTitleSection.swift
//  Holo
//
//  任务详情标题区（完成圈 + 标题 + 重复徽章 + 描述 + 语音）——
//  2026-10-24 随真机主线程栈溢出排险从 TaskDetailView 拆出（纯搬移，界面/行为零变化）。
//

import SwiftUI

// MARK: - 描述输入框高度自适应

private enum TaskDescriptionEditorLayout {
    static let minHeight: CGFloat = 46
    static let maxHeight: CGFloat = 132
    static let horizontalInset: CGFloat = 5
    static let verticalInset: CGFloat = 8

    static func height(for measuredTextHeight: CGFloat) -> CGFloat {
        min(max(measuredTextHeight, minHeight), maxHeight)
    }
}

private struct TaskDescriptionHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = TaskDescriptionEditorLayout.minHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 标题区

struct TaskDetailTitleSection: View {

    let existingTask: TodoTask?
    @Binding var title: String
    @Binding var description: String
    @Binding var showTaskVoiceInput: Bool
    @Binding var smartSummaryEnabled: Bool
    let isSplittingTaskVoice: Bool
    let isCompletionPending: Bool
    let repeatType: RepeatType
    var isTitleFocused: FocusState<Bool>.Binding
    let toggleCompletion: () -> Void

    @State private var descriptionEditorHeight = TaskDescriptionEditorLayout.minHeight

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 12) {
                // 编辑模式：完成切换
                if let task = existingTask {
                    Button {
                        toggleCompletion()
                    } label: {
                        // 撤回窗口内视觉与已完成一致（对齐列表/看板的完成中表现）
                        let isDone = task.completed || isCompletionPending
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(isDone ? .holoSuccess : .holoTextSecondary)
                    }
                    .buttonStyle(.plain)
                }

                TextField("输入任务名称", text: $title)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .strikethrough(existingTask?.completed == true || isCompletionPending, color: .holoTextSecondary)
                    .focused(isTitleFocused)
            }

            // 重复任务徽章
            if let task = existingTask, task.repeatRule != nil, !task.completed {
                HStack(spacing: 4) {
                    Image(systemName: "repeat")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(repeatType.displayTitle)重复")
                        .font(.holoTinyLabel)
                }
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.holoPrimary.opacity(0.1))
                .clipShape(Capsule())
                .padding(.leading, 36)
            }

            ZStack(alignment: .topLeading) {
                descriptionHeightMeasurer

                TextEditor(text: $description)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .frame(height: descriptionEditorHeight)
                    // 始终允许内部滚动：内容少时高度跟随内容变矮，触摸自然交给外层
                    // ScrollView；若按高度翻转 scrollDisabled（底层 UITextView
                    // .isScrollEnabled）会触发排版引擎反复重建，输入时光标卡顿。
                    .scrollContentBackground(.hidden)

                if description.isEmpty {
                    Text("添加描述、完成标准或需要注意的点")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPlaceholder)
                        .padding(.top, TaskDescriptionEditorLayout.verticalInset)
                        .padding(.leading, TaskDescriptionEditorLayout.horizontalInset)
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(TaskDescriptionHeightPreferenceKey.self) { measuredHeight in
                descriptionEditorHeight = TaskDescriptionEditorLayout.height(for: measuredHeight)
            }

            taskDescriptionVoiceControls
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var taskDescriptionVoiceControls: some View {
        HStack(spacing: 8) {
            Button {
                HapticManager.selection()
                showTaskVoiceInput = true
            } label: {
                if isSplittingTaskVoice {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.holoPrimary)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.holoPrimary)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
                }
            }
            .buttonStyle(.plain)
            .disabled(isSplittingTaskVoice)
            .accessibilityLabel(String(localized: "语音输入"))
            .accessibilityHint(String(localized: "录音并将识别结果插入到任务描述"))

            Button {
                smartSummaryEnabled.toggle()
            } label: {
                Image(systemName: smartSummaryEnabled ? "sparkles" : "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(smartSummaryEnabled ? .holoToolAI : .holoTextSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(smartSummaryEnabled ? Color.holoToolAI.opacity(0.12) : Color.holoCardBackground)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(smartSummaryEnabled ? String(localized: "关闭智能总结") : String(localized: "开启智能总结"))
        }
    }

    private var descriptionHeightMeasurer: some View {
        Text(description.isEmpty ? " " : description + "\n")
            .font(.holoBody)
            .foregroundColor(.clear)
            .padding(.horizontal, TaskDescriptionEditorLayout.horizontalInset)
            .padding(.vertical, TaskDescriptionEditorLayout.verticalInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: TaskDescriptionHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            )
            .allowsHitTesting(false)
    }
}
