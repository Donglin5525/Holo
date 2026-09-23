//
//  TaskContentEditSheet.swift
//  Holo
//
//  AI 建任务确认卡的「调整内容」弹层：标题 / 描述 / 子条目 / 优先级 / 重复。
//  完成时以 renderData patch 形式回传（ChatViewModel 写回待确认项）。
//

import SwiftUI

struct TaskContentEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    struct Prefill {
        var title: String
        var description: String
        var subtasks: [String]
        /// "0"~"3"（TaskPriority rawValue）
        var priorityRaw: String
        var repeatEnabled: Bool
        var repeatType: RepeatType
        var repeatInterval: Int
        var repeatWeekdays: Set<Weekday>
        var repeatMonthDay: Int
    }

    let prefill: Prefill
    /// 完成回调：回传 renderData 增量 patch
    let onDone: ([String: String]) -> Void

    @State private var title: String
    @State private var detailText: String
    @State private var subtasks: [String]
    @State private var priority: TaskPriority
    @State private var repeatEnabled: Bool
    @State private var repeatType: RepeatType
    @State private var repeatInterval: Int
    @State private var repeatWeekdays: Set<Weekday>
    @State private var repeatMonthDay: Int
    @FocusState private var titleFocused: Bool

    init(prefill: Prefill, onDone: @escaping ([String: String]) -> Void) {
        self.prefill = prefill
        self.onDone = onDone
        self._title = State(initialValue: prefill.title)
        self._detailText = State(initialValue: prefill.description)
        self._subtasks = State(initialValue: prefill.subtasks)
        self._priority = State(initialValue: TaskPriority(rawValue: Int16(prefill.priorityRaw) ?? 1) ?? .medium)
        self._repeatEnabled = State(initialValue: prefill.repeatEnabled)
        self._repeatType = State(initialValue: prefill.repeatType)
        self._repeatInterval = State(initialValue: prefill.repeatInterval)
        self._repeatWeekdays = State(initialValue: prefill.repeatWeekdays)
        self._repeatMonthDay = State(initialValue: prefill.repeatMonthDay)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: HoloSpacing.lg) {
                        titleSection
                        subtasksSection
                        descriptionSection
                        prioritySection
                        repeatSection
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                    .padding(.bottom, HoloSpacing.lg)
                }
            }
            .navigationTitle("调整内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        onDone(buildPatch())
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                    .disabled(trimmedTitle.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sections

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("标题")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            TextField("任务标题", text: $title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .focused($titleFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.sm)
        }
    }

    private var subtasksSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("条目")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            ForEach(Array(subtasks.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: HoloSpacing.sm) {
                    TextField("条目内容", text: Binding(
                        get: { subtasks.indices.contains(index) ? subtasks[index] : "" },
                        set: { if subtasks.indices.contains(index) { subtasks[index] = $0 } }
                    ))
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                    Button {
                        guard subtasks.indices.contains(index) else { return }
                        subtasks.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.holoTextSecondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.sm)
            }

            Button {
                subtasks.append("")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                    Text("添加条目")
                        .font(.holoBody)
                }
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("描述")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            TextEditor(text: $detailText)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.sm)
        }
    }

    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("优先级")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Picker("", selection: $priority) {
                ForEach(TaskPriority.allCases, id: \.self) { level in
                    Text(level.displayTitle).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "repeat")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .frame(width: 22)

                Text("重复")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                Toggle("", isOn: $repeatEnabled)
                    .labelsHidden()
                    .tint(.holoPrimary)
            }

            if repeatEnabled {
                FlowLayout(spacing: HoloSpacing.xs) {
                    ForEach([RepeatType.daily, .weekly, .monthly, .yearly, .custom], id: \.self) { type in
                        RepeatTypeChip(
                            type: type,
                            isSelected: repeatType == type,
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    repeatType = type
                                    if type == .custom && repeatWeekdays.isEmpty {
                                        repeatWeekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
                                    }
                                }
                            }
                        )
                    }
                }

                if repeatType == .custom {
                    HStack(spacing: HoloSpacing.xs) {
                        ForEach([Weekday.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday], id: \.self) { weekday in
                            WeekdayChip(
                                weekday: weekday,
                                isSelected: repeatWeekdays.contains(weekday),
                                onTap: {
                                    if repeatWeekdays.contains(weekday) {
                                        repeatWeekdays.remove(weekday)
                                    } else {
                                        repeatWeekdays.insert(weekday)
                                    }
                                }
                            )
                        }
                    }
                }

                if repeatType == .monthly {
                    HStack(spacing: HoloSpacing.xs) {
                        Text("每月")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)

                        Picker("", selection: $repeatMonthDay) {
                            ForEach(1...31, id: \.self) { day in
                                Text("\(day)").tag(day)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.holoPrimary)

                        Text("日")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.sm)
    }

    // MARK: - Patch

    private func buildPatch() -> [String: String] {
        var patch: [String: String] = [
            "title": trimmedTitle,
            "description": detailText,
            "priority": String(priority.rawValue)
        ]

        let cleanedSubtasks = subtasks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // 单项合法：走用户覆盖键（AI 通道 subtasks 需 ≥2 项才算清单）
        patch[TaskPendingDefaults.userSubtasksKey] = cleanedSubtasks.joined(separator: "\n")

        patch["repeatEnabled"] = repeatEnabled ? "true" : "false"
        if repeatEnabled {
            patch["repeatType"] = repeatType.rawValue
            patch["repeatInterval"] = String(max(1, repeatInterval))
            if repeatType == .custom {
                patch["repeatWeekdays"] = repeatWeekdays
                    .map(\.rawValue)
                    .sorted()
                    .map(String.init)
                    .joined(separator: ",")
            } else {
                patch.removeValue(forKey: "repeatWeekdays")
            }
            if repeatType == .monthly {
                patch["repeatMonthDay"] = String(repeatMonthDay)
            } else {
                patch.removeValue(forKey: "repeatMonthDay")
            }
            patch["repeatSummary"] = repeatSummaryText
        } else {
            patch.removeValue(forKey: "repeatType")
            patch.removeValue(forKey: "repeatInterval")
            patch.removeValue(forKey: "repeatWeekdays")
            patch.removeValue(forKey: "repeatMonthDay")
            patch.removeValue(forKey: "repeatSummary")
        }

        return patch
    }

    private var repeatSummaryText: String {
        switch repeatType {
        case .daily: return repeatInterval > 1 ? "每 \(repeatInterval) 天" : "每天"
        case .weekly: return repeatInterval > 1 ? "每 \(repeatInterval) 周" : "每周"
        case .monthly: return repeatInterval > 1 ? "每 \(repeatInterval) 月" : "每月"
        case .yearly: return repeatInterval > 1 ? "每 \(repeatInterval) 年" : "每年"
        case .custom:
            let names = repeatWeekdays.map(\.displayTitle).sorted().joined(separator: "、")
            return names.isEmpty ? "自定义" : "每\(names)"
        }
    }
}
