//
//  TaskQuadrantMoveSheet.swift
//  Holo
//
//  非拖动的移动入口（多视图方案 §6.3-10 / §7 详情「移动到象限」）：
//  四格目标选择；移动只写两轴、紧急性转手动；同格 no-op 静默关闭。
//

import SwiftUI

struct TaskQuadrantMoveSheet: View {

    let snapshot: TaskRecordSnapshot
    let repository: TodoRepository
    let now: Date
    let calendar: Calendar
    var onDone: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    init(
        snapshot: TaskRecordSnapshot,
        repository: TodoRepository,
        now: Date,
        calendar: Calendar,
        onDone: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.repository = repository
        self.now = now
        self.calendar = calendar
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    Text("移动后会调整重要性与紧急性，紧急性改为手动判断；计划、截止和提醒保持原值。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: HoloSpacing.sm), GridItem(.flexible())], spacing: HoloSpacing.sm) {
                        ForEach(TaskQuadrant.overviewOrder, id: \.self) { quadrant in
                            moveChoice(quadrant)
                        }
                    }

                    if let message = errorMessage {
                        HoloInlineState(kind: .failure, message: message, actionTitle: String(localized: "重试")) {
                            errorMessage = nil
                        }
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle(String(localized: "移动到象限"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func moveChoice(_ quadrant: TaskQuadrant) -> some View {
        Button {
            commit(to: quadrant)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(quadrant.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(quadrant.tintColor)
                Text(quadrant.subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(quadrant.tintColor.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(HoloSpacing.sm + 4)
            .background(quadrant.backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "移动到\(quadrant.displayTitle)"))
    }

    private func commit(to quadrant: TaskQuadrant) {
        switch TaskPresentationActionCoordinator.shared.commitQuadrantMove(
            taskID: snapshot.id,
            target: quadrant,
            repository: repository,
            now: now,
            calendar: calendar
        ) {
        case .applied:
            dismiss()
            onDone?()
        case .noOp:
            // 目标等于当前实时解析格：静默关闭，不提示（§6.2）
            dismiss()
            onDone?()
        case .taskUnavailable:
            errorMessage = String(localized: "任务已发生变化，请重新查看")
        case .saveFailed:
            errorMessage = String(localized: "移动未保存，请重试")
        }
    }
}
