//
//  TaskTriageSheet.swift
//  Holo
//
//  连续整理（2026-10-06 任务重构方案 §6.1）：打开时冻结当前范围未判断重要性的
//  UUID 队列；逐项判断重要性（紧急方式默认保留）；保存成功才进下一项；
//  队列成员失效（删除/归档/完成/已被整理）重新读取并跳过。
//

import SwiftUI
import os.log

struct TaskTriageSheet: View {

    @ObservedObject var repository: TodoRepository
    /// 打开时冻结的队列（快照值：只留展示所需事实，不跨步持托管对象）
    let queue: [TaskRecordSnapshot]

    @Environment(\.dismiss) private var dismiss

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskTriageSheet")

    @State private var cursor: Int = 0
    @State private var currentImportance: TaskImportance = .unknown
    @State private var currentUrgencyMode: TaskUrgencyMode = .auto
    @State private var savedCount = 0
    @State private var skippedCount = 0
    @State private var isSaving = false
    @State private var itemError: String? = nil
    @State private var finished = false

    var body: some View {
        NavigationStack {
            Group {
                if finished {
                    summaryView
                } else if cursor < queue.count {
                    triageView(queue[cursor])
                } else {
                    // 队列走完（含中途跳过推进到末尾）
                    doneView
                }
            }
            .background(Color.holoBackground)
            .navigationTitle(String(localized: "开始整理"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 随时关闭：已保存的保留，当前未提交的选择放弃（§6.1）
                    Button(String(localized: "关闭")) { finished = true }
                }
            }
        }
    }

    // MARK: - 单项整理

    private func triageView(_ item: TaskRecordSnapshot) -> some View {
        let effectiveDue = item.effectiveDue(calendar: TaskAnalyticsPeriod.makeCalendar())
        return ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                // 位置与进度
                Text(String(localized: "第 \(cursor + 1) / \(queue.count) 项"))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                // 任务卡：标题 + 截止 + 清单 + 描述摘要（§6.1）
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(3)
                    HStack(spacing: 10) {
                        if let due = effectiveDue {
                            Label {
                                Text(TaskCreationSheet.formatDue(item.dueDate ?? due, isAllDay: item.isAllDay))
                                    .font(.holoCaption)
                            } icon: {
                                Image(systemName: "calendar")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(item.isOverdue(asOf: Date(), calendar: TaskAnalyticsPeriod.makeCalendar()) ? .holoError : .holoTextSecondary)
                        } else {
                            Label {
                                Text("未设截止日期")
                                    .font(.holoCaption)
                            } icon: {
                                Image(systemName: "calendar.badge.minus")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.holoTextSecondary)
                        }
                        Label {
                            Text(item.listID == nil ? String(localized: "收件箱") : (item.listName ?? String(localized: "未归属清单")))
                                .font(.holoCaption)
                        } icon: {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.holoTextSecondary)
                    }
                    if let note = item.note, !note.isEmpty {
                        Text(note)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(3)
                    }
                }
                .padding(HoloSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))

                // 重要性判断（主问题）
                Text("这件事重要吗？")
                    .font(.holoBody.weight(.semibold))
                    .foregroundColor(.holoTextPrimary)

                HStack(spacing: 8) {
                    triageOption(.p1, label: String(localized: "P1 重要"))
                    triageOption(.p2, label: String(localized: "P2 一般"))
                    triageOption(.p3, label: String(localized: "P3 不重要"))
                }

                // 紧急方式：默认保留任务原有方式（§6.1）
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text(String(localized: "紧急程度"))
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    HStack(spacing: 8) {
                        triageUrgencyOption(.auto, label: TaskUrgencyMode.auto.displayTitle)
                        triageUrgencyOption(.p1, label: "P1")
                        triageUrgencyOption(.p2, label: "P2")
                        triageUrgencyOption(.p3, label: "P3")
                    }
                    Text(TaskQuadrantResolver.urgencyExplanation(
                        mode: currentUrgencyMode,
                        effectiveDue: effectiveDue,
                        now: Date(),
                        calendar: TaskAnalyticsPeriod.makeCalendar()
                    ))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                }

                if let itemError {
                    Text(itemError)
                        .font(.holoCaption)
                        .foregroundColor(.holoError)
                }
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.md)
            .padding(.bottom, HoloSpacing.xl)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    saveAndAdvance(item)
                } label: {
                    Text("保存并继续")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                                .fill(currentImportance == .unknown ? Color.holoPrimary.opacity(0.35) : Color.holoPrimary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(currentImportance == .unknown || isSaving)
                if currentImportance == .unknown {
                    Text("先判断这件事是否重要")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
                Button {
                    skip()
                } label: {
                    Text("先跳过")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.vertical, HoloSpacing.sm)
            .background(.ultraThinMaterial)
        }
        .onAppear {
            loadDraft(from: item)
        }
        .onChange(of: cursor) { _, _ in
            if cursor < queue.count {
                loadDraft(from: queue[cursor])
            }
        }
    }

    private func triageOption(_ value: TaskImportance, label: String) -> some View {
        Button {
            currentImportance = value
            itemError = nil
        } label: {
            Text(label)
                .font(.system(size: 15, weight: currentImportance == value ? .semibold : .regular))
                .foregroundColor(currentImportance == value ? .white : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    Capsule().fill(currentImportance == value ? Color.holoPrimary : Color.holoCardBackground)
                )
                .overlay(
                    Capsule().strokeBorder(currentImportance == value ? Color.clear : Color.holoDivider, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(currentImportance == value ? .isSelected : [])
    }

    private func triageUrgencyOption(_ value: TaskUrgencyMode, label: String) -> some View {
        Button {
            currentUrgencyMode = value
        } label: {
            Text(label)
                .font(.system(size: 13, weight: currentUrgencyMode == value ? .semibold : .regular))
                .foregroundColor(currentUrgencyMode == value ? .white : .holoTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(currentUrgencyMode == value ? Color.holoPrimary.opacity(0.75) : Color.holoCardBackground)
                )
                .overlay(
                    Capsule().strokeBorder(currentUrgencyMode == value ? Color.clear : Color.holoDivider, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(currentUrgencyMode == value ? .isSelected : [])
    }

    // MARK: - 结束与汇总

    private var doneView: some View {
        summaryView
            .onAppear { finished = true }
    }

    private var summaryView: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundColor(.holoPrimary)
            Text("本轮整理完成")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
            Text(String(localized: "已整理 \(savedCount) 项 · 跳过 \(skippedCount) 项"))
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Button {
                dismiss()
            } label: {
                Text("返回任务")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                            .fill(Color.holoPrimary)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, HoloSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 步进逻辑

    /// 每步从快照恢复默认（保留任务原有紧急方式，§6.1）
    private func loadDraft(from item: TaskRecordSnapshot) {
        currentImportance = .unknown
        currentUrgencyMode = item.urgencyMode
        itemError = nil
    }

    private func saveAndAdvance(_ item: TaskRecordSnapshot) {
        guard currentImportance != .unknown, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            // 操作前按 UUID 重新获取规范副本并验证未删除（§6.1/§8.2）
            guard let task = repository.findTask(by: item.id) else {
                Self.logger.notice("整理项已不存在，跳过：\(item.id.uuidString, privacy: .public)")
                advance()
                return
            }
            // 已被其他设备整理过的项不重写（幂等跳过，§6.1）
            if task.importance != .unknown {
                advance()
                return
            }
            try repository.updateTaskClassification(
                taskID: item.id,
                importance: currentImportance,
                urgencyMode: currentUrgencyMode == item.urgencyMode ? nil : currentUrgencyMode
            )
            savedCount += 1
            advance()
        } catch {
            // 单项失败停留并保留本项选择；不回滚共享上下文（§6.1）
            itemError = String(localized: "保存失败，请重试")
        }
    }

    private func skip() {
        skippedCount += 1
        advance()
    }

    private func advance() {
        itemError = nil
        if cursor + 1 >= queue.count {
            finished = true
        } else {
            cursor += 1
        }
    }
}
