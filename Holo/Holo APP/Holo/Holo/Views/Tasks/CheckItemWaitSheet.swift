//
//  CheckItemWaitSheet.swift
//  Holo
//
//  「先等等」弹层（2026-10-11 拆开瘦身定稿）
//
//  - 自由输入为主：等什么由用户一句话写，无预设死名单
//  - AI 候选来自拆解时一次性生成、存在子任务上的本地缓存（waitHints），
//    打开即见、零调用、断网也在；手动加的步骤没有候选，只有输入框
//  - 明天上午 9:00 提醒开关；推送文案沿用「之前在等的事，看看有没有进展」族
//

import SwiftUI

struct CheckItemWaitSheet: View {

    let item: CheckItem
    /// 确认（note 可为空串；remindAt 为 nil 表示不提醒）
    let onConfirm: (_ note: String, _ remindAt: Date?) -> Void

    @State private var note: String = ""
    @State private var remind: Bool = true
    @Environment(\.dismiss) private var dismiss

    private static var tomorrowNine: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题区（居左 + 右上关闭）
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("这一步在等什么？")
                        .font(.holoHeading)
                    Text("别的步骤不受影响")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer(minLength: 12)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.holoToolBackground.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("关闭"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("也可以自己写一句", text: $note)
                        .font(.holoBody)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: HoloRadius.md)
                                .fill(Color.holoNestedCardBackground)
                        )
                        .accessibilityIdentifier("checkItemWaitInput")

                    if !item.waitHints.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.holoTinyLabel)
                                    .foregroundStyle(Color.holoAI)
                                Text("AI 拆解时猜你在等：")
                                    .font(.holoTinyLabel)
                                    .foregroundColor(.holoTextSecondary)
                            }
                            ForEach(item.waitHints, id: \.self) { hint in
                                Button {
                                    note = hint
                                } label: {
                                    Text(verbatim: hint)
                                        .font(.holoBody)
                                        .foregroundColor(.holoTextPrimary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 11)
                                        .background(
                                            RoundedRectangle(cornerRadius: HoloRadius.md)
                                                .fill(note == hint ? Color.holoPrimary.opacity(0.12) : Color.holoNestedCardBackground)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Toggle(isOn: $remind) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("明天上午 9:00 提醒我")
                                .font(.holoBody)
                            Text("到时候推给你：之前在等的事，看看有没有进展")
                                .font(.holoTinyLabel)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(.green)
                    .padding(.vertical, 4)
                }
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 0)

            Button {
                onConfirm(note.trimmingCharacters(in: .whitespaces), remind ? Self.tomorrowNine : nil)
                dismiss()
            } label: {
                Text("先放着，等我回来")
                    .font(.holoBody.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .fill(Color.holoPrimary)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .accessibilityIdentifier("checkItemWaitConfirm")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.holoCardBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            note = item.waitNote ?? ""
        }
    }
}
