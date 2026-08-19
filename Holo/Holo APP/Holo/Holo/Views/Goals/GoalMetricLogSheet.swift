//
//  GoalMetricLogSheet.swift
//  Holo
//
//  量化目标「记一笔」轻量录入（manual 源专用）
//  累积型记每次增量（自动累加）；达标型记当前水平（取最新一条算进度）
//

import SwiftUI

struct GoalMetricLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goal: Goal

    @State private var valueText = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var isSaving = false
    @State private var saveError: String?

    private var unitText: String { goal.metricUnitText }

    private var isTargetKind: Bool { goal.goalKindEnum == .target }

    private var canSave: Bool {
        !isSaving && Double(valueText) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    // 数值
                    VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                        Text(isTargetKind ? "当前值\(unitSuffix)" : "本次数值\(unitSuffix)")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                        TextField(isTargetKind ? "如 72.5" : "如 5", text: $valueText)
                            .keyboardType(.decimalPad)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .padding(HoloSpacing.sm)
                            .background(Color.holoBackground)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                        Text(isTargetKind
                             ? "记录当前水平，进度取最新一条计算"
                             : "记录每次的量，会自动累加到目标进度")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                    }

                    // 备注
                    VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                        Text("备注")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                        TextField("选填", text: $note, axis: .vertical)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1...2)
                            .padding(HoloSpacing.sm)
                            .background(Color.holoBackground)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
                    }

                    // 日期
                    VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                        Text("日期")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)
                        DatePicker(
                            "日期",
                            selection: $date,
                            in: (goal.baselineDate ?? goal.createdAt)...Date(),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    }
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle(isTargetKind ? "记当前水平" : "记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    save()
                } label: {
                    Text(isSaving ? "保存中" : "保存")
                        .font(.holoBody)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSave ? Color.holoPrimary : Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .disabled(!canSave)
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
                .background(Color.holoCardBackground)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: -2)
            }
            .alert("保存失败", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var unitSuffix: String {
        unitText.isEmpty ? "" : "（\(unitText)）"
    }

    private func save() {
        guard let value = Double(valueText) else { return }
        isSaving = true
        DispatchQueue.main.async {
            do {
                _ = try GoalRepository.shared.addMetricLog(
                    for: goal,
                    value: value,
                    date: date,
                    note: note.isEmpty ? nil : note
                )
                GoalNotificationService.broadcastGoalDataChange()
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}
