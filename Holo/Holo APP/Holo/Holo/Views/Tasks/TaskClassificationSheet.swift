//
//  TaskClassificationSheet.swift
//  Holo
//
//  轻重缓急编辑弹层（方案 §6.2；2026-10-07 P 档体系）：首页「更多」直接分类
//  （独立保存）与详情子弹层（写详情草稿、确定回详情沿用详情保存时点）共用视图体。
//  内容与新建任务页展开态同一套 P 档双滑杆编辑器（TaskPriorityLevers）。
//

import SwiftUI

struct TaskClassificationSheet: View {

    /// 确定回调：返回两轴新值（保存语义由调用方决定）
    let onConfirm: (TaskImportance, TaskUrgencyMode) -> Void
    @Environment(\.dismiss) private var dismiss

    /// 当前任务的有效截止（auto 模式的折算与解释依据）
    var contextEffectiveDue: Date? = nil

    @State private var importance: TaskImportance
    @State private var urgencyMode: TaskUrgencyMode

    init(
        initialImportance: TaskImportance,
        initialUrgencyMode: TaskUrgencyMode,
        contextEffectiveDue: Date? = nil,
        onConfirm: @escaping (TaskImportance, TaskUrgencyMode) -> Void
    ) {
        self.contextEffectiveDue = contextEffectiveDue
        self.onConfirm = onConfirm
        _importance = State(initialValue: initialImportance)
        _urgencyMode = State(initialValue: initialUrgencyMode)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                TaskClassificationLeverEditor(
                    importance: $importance,
                    urgencyMode: $urgencyMode,
                    effectiveDue: contextEffectiveDue
                )
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.xl)
            }
            .background(Color.holoBackground)
            .navigationTitle(String(localized: "轻重缓急"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "确定")) {
                        onConfirm(importance, urgencyMode)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
