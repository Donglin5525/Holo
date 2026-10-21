//
//  HabitRecordEditSheet.swift
//  Holo
//
//  记录编辑弹层（2026-10-15 随旧详情页退役从 HabitDetailView.swift 拆出；
//  今天页概览弹层与单习惯回顾页共用）：
//  数值记录改值/备注（测量允许 0）；打卡记录补备注（方案 §5.4）
//

import SwiftUI

struct HabitRecordEditSheet: View {
    let record: HabitRecord
    /// 习惯记录方式：打卡型无数值概念，只补备注；计数校验 >0、测量校验 ≥0
    let kind: HabitRowKind
    let unit: String?
    var onSave: (Double?, String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var valueText: String = ""
    @State private var note: String = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var initialValue = ""
    @State private var initialNote = ""
    @State private var showDismissAlert = false
    @FocusState private var valueFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
            Text(String(localized: "编辑记录"))
                .font(.holoHeading)
                .foregroundColor(.holoToolText)

            if kind != .checkIn {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField(String(localized: "数值"), text: $valueText)
                            .keyboardType(.decimalPad)
                .accessibilityIdentifier("habit-record-edit-value")
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .foregroundColor(.holoToolText)
                            .focused($valueFocused)
                        if let unit, !unit.isEmpty {
                            Text(unit)
                                .font(.system(size: 14))
                                .foregroundColor(.holoToolTextSecondary)
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolError)
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolInset))
            }

            TextField(String(localized: "备注"), text: $note)
                .font(.holoBody)
                .foregroundColor(.holoToolText)
                .padding()
                .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolInset))

            HStack(spacing: HoloSpacing.md) {
                Button {
                    if hasUnsavedChanges { showDismissAlert = true } else { dismiss() }
                } label: {
                    Text(String(localized: "取消"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.holoToolText)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule().fill(Color.holoToolInset))
                }
                .buttonStyle(HoloPressStyle())

                Button {
                    Task { await save() }
                } label: {
                    Text(isSaving ? String(localized: "保存中…") : String(localized: "保存"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.holoToolOnAction)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule().fill(Color.holoToolAction))
                }
                .buttonStyle(HoloPressStyle())
            }
            .disabled(isSaving)
            if kind == .checkIn, let errorMessage {
                Text(errorMessage).holoText(.supporting).foregroundColor(.holoToolError)
            }
            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.lg)
        .presentationDetents([.height(300)])
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "完成")) { valueFocused = false }
            }
        }
        .onAppear {
            if let v = record.valueDouble {
                valueText = HabitPresentationProjector.formatValue(v)
            }
            note = record.note ?? ""
            initialValue = valueText
            initialNote = note
        }
        .interactiveDismissDisabled(isSaving || hasUnsavedChanges)
        .unsavedChangesAlert(isPresented: $showDismissAlert) { dismiss() }
    }

    private var hasUnsavedChanges: Bool { valueText != initialValue || note != initialNote }

    private func save() async {
        guard !isSaving else { return }
        var newValue: Double? = nil
        if record.valueDouble != nil {
            let formatter = NumberFormatter()
            formatter.locale = Locale.current
            formatter.numberStyle = .decimal
            guard let number = formatter.number(from: valueText.trimmingCharacters(in: .whitespaces)),
                  let parsed = number as? Double, parsed.isFinite,
                  kind == .count ? parsed > 0 : parsed >= 0 else {
                errorMessage = String(localized: kind == .count ? "计数值需要大于 0" : "请输入有效的数值（0 及以上）")
                valueFocused = true
                return
            }
            newValue = parsed
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        if await onSave(newValue, note.isEmpty ? nil : note) {
            dismiss()
        } else {
            errorMessage = String(localized: "这次没有保存成功，内容还在，请重试")
        }
    }
}
