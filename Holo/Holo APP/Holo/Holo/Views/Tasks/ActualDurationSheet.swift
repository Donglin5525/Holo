//
//  ActualDurationSheet.swift
//  Holo
//
//  实际用时确认（计划 vs 实际，三期）
//  完成带时间段的任务时弹出：可选快捷时长或自定义，也可跳过
//

import SwiftUI

struct ActualDurationSheet: View {
    @Environment(\.dismiss) var dismiss
    let task: TodoTask
    let repository: TodoRepository

    @State private var selectedMinutes: Int

    init(task: TodoTask, repository: TodoRepository) {
        self.task = task
        self.repository = repository
        let planned = task.plannedDurationMinutes ?? 60
        _selectedMinutes = State(initialValue: planned)
    }

    private var quickOptions: [Int] {
        var options: Set<Int> = [15, 30, 45, 60, 90, 120]
        if let planned = task.plannedDurationMinutes {
            options.insert(planned)
        }
        return options.sorted()
    }

    private var plannedText: String? {
        guard let minutes = task.plannedDurationMinutes else { return nil }
        return Self.durationText(minutes)
    }

    static func durationText(_ minutes: Int) -> String {
        minutes >= 60
            ? minutes % 60 == 0 ? "\(minutes / 60) 小时" : String(format: "%.1f 小时", Double(minutes) / 60)
            : "\(minutes) 分钟"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                VStack(spacing: HoloSpacing.lg) {
                    VStack(spacing: HoloSpacing.sm) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 28))
                            .foregroundColor(.holoPrimary)

                        Text("实际用了多久？")
                            .font(.holoTitle3)
                            .foregroundColor(.holoTextPrimary)

                        if let plannedText {
                            Text("计划 \(plannedText) · 记录后可对比计划与实际")
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                    .padding(.top, HoloSpacing.xl)

                    // 快捷时长
                    FlowOptionGrid(options: quickOptions, selected: selectedMinutes) { minutes in
                        selectedMinutes = minutes
                    }

                    // 自定义微调
                    HStack(spacing: HoloSpacing.md) {
                        Button {
                            selectedMinutes = max(5, selectedMinutes - 15)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.holoPrimary)
                        }
                        .buttonStyle(.plain)

                        Text(Self.durationText(selectedMinutes))
                            .font(.holoTitle2)
                            .foregroundColor(.holoTextPrimary)
                            .frame(minWidth: 110)

                        Button {
                            selectedMinutes = min(24 * 60, selectedMinutes + 15)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.holoPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))

                    Spacer()

                    // 主操作
                    VStack(spacing: HoloSpacing.sm) {
                        Button {
                            try? repository.setActualDuration(task, minutes: selectedMinutes)
                            HapticManager.success()
                            dismiss()
                        } label: {
                            Text("记录")
                                .font(.holoBody)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: HoloRadius.lg).fill(Color.holoPrimary))
                        }
                        .buttonStyle(.plain)

                        Button("跳过，不记录") { dismiss() }
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.bottom, HoloSpacing.lg)
            }
            .navigationTitle("实际用时")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .presentationDetents([.height(420), .large])
    }
}

/// 快捷时长胶囊流式排布（自动换行的简易实现）
private struct FlowOptionGrid: View {
    let options: [Int]
    let selected: Int
    let onTap: (Int) -> Void

    var body: some View {
        VStack(spacing: HoloSpacing.sm) {
            ForEach(0..<rows.count, id: \.self) { rowIndex in
                HStack(spacing: HoloSpacing.sm) {
                    ForEach(rows[rowIndex], id: \.self) { minutes in
                        let label = ActualDurationSheet.durationText(minutes)
                        Button {
                            onTap(minutes)
                        } label: {
                            Text(label)
                                .font(.system(size: 13, weight: selected == minutes ? .bold : .regular))
                                .foregroundColor(selected == minutes ? .white : .holoTextPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(selected == minutes ? Color.holoPrimary : Color.holoCardBackground)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var rows: [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for minutes in options {
            if current.count >= 4 {
                result.append(current)
                current = []
            }
            current.append(minutes)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
