//
//  TaskPostponeSheet.swift
//  Holo
//
//  延期面板：选项由 TaskPostponePolicy 按任务形态生成（唯一规则源）。
//  延期是立即生效操作，撤回由调用方的横幅承担；「自定义」内嵌日期选择，不跳转。
//

import SwiftUI

struct TaskPostponeSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// 入参用纯值而非 TodoTask：详情页传编辑态（未保存的修改也要立即反映），
    /// 列表页传库值；绑实体会让面板读到滞后于界面的旧数据。
    let title: String
    let dueDate: Date?
    let isAllDay: Bool
    let isOverdue: Bool
    let onPostpone: (TaskPostponeOption) -> Void

    /// 自定义档：内嵌日期选择展开态
    @State private var customDate = Date()

    private var options: [TaskPostponeOption] {
        TaskPostponePolicy.options(
            dueDate: dueDate ?? Date(),
            isAllDay: isAllDay,
            isOverdue: isOverdue
        )
    }

    private var delayOptions: [TaskPostponeOption] {
        options.filter { isDelayKind($0) }
    }

    private var anotherDayOptions: [TaskPostponeOption] {
        options.filter { $0.kind != .custom && !isDelayKind($0) }
    }

    private func isDelayKind(_ option: TaskPostponeOption) -> Bool {
        if case .delayMinutes = option.kind { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题：任务名 + 当前时间胶囊 + 现在时刻
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    currentDueTag
                }

                Text("现在 \(nowText)，选择新的截止时间")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.sm)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    if !delayOptions.isEmpty {
                        sectionLabel("今天内顺延")
                        optionGrid(delayOptions)
                    }

                    sectionLabel(delayOptions.isEmpty ? "延期到" : "推到另一天")
                    optionGrid(anotherDayOptions)

                    customSection

                    footnote
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.lg)
            }
        }
        .background(Color.holoBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // 自定义档初始值：保持原时刻的前提下顺延一天，减少无效拨动
            let calendar = Calendar.current
            let base = dueDate ?? Date()
            customDate = calendar.date(byAdding: .day, value: 1, to: base) ?? base
        }
    }

    // MARK: - Sections

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.holoTextSecondary)
            .padding(.leading, 2)
    }

    private func optionGrid(_ options: [TaskPostponeOption]) -> some View {
        // 过期任务的天数档有 4 个（今天/明天/三天后/一周后），换 4 列避免孤行
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 9),
            count: options.count == 4 ? 4 : 3
        )
        return LazyVGrid(columns: columns, spacing: 9) {
            ForEach(options) { option in
                optionButton(option)
            }
        }
    }

    private func optionButton(_ option: TaskPostponeOption) -> some View {
        Button {
            HapticManager.selection()
            onPostpone(option)
            dismiss()
        } label: {
            VStack(spacing: 3) {
                Text(option.label)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(option.isCustom ? .holoTextSecondary : .holoTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(option.subLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .fill(option.isPrimary
                          ? Color.holoPrimary.opacity(0.08)
                          : Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .strokeBorder(
                        option.isPrimary
                        ? Color.holoPrimary.opacity(0.35)
                        : Color.holoDivider,
                        lineWidth: 1
                    )
            )
            // 背景必须进 label 内，plain 按钮热区才不会被裁到文字
            .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 自定义档：内嵌日期选择（定时带时刻，全天只选日期）
    private var customSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("自定义")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.holoTextSecondary)
                .padding(.leading, 2)

            DatePicker(
                "自定义",
                selection: $customDate,
                in: Date()...,
                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .tint(.holoPrimary)

            Button {
                HapticManager.selection()
                let customOption = TaskPostponeOption(
                    id: "custom-applied",
                    label: "自定义",
                    subLabel: "",
                    targetDate: customDate,
                    isAllDay: isAllDay,
                    kind: .custom,
                    isPrimary: false
                )
                onPostpone(customOption)
                dismiss()
            } label: {
                Text("延期到\(isAllDay ? "这一天" : "这个时间")")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                            .fill(LinearGradient(
                                colors: [.holoPrimary, .holoPrimaryDark],
                                startPoint: .leading, endPoint: .trailing
                            ))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .strokeBorder(Color.holoDivider, lineWidth: 1)
        )
        .padding(.top, HoloSpacing.xs)
    }

    private var footnote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoPrimary)

            Text(isAllDay
                 ? "全天任务延期后仍是全天；已设置的提醒会自动跟随新日期。"
                 : "跨天延期保留原时刻；提醒是「截止前 N 分钟」，会自动跟随。")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                .fill(Color.holoCardBackground.opacity(0.6))
        )
        .padding(.top, HoloSpacing.xs)
    }

    // MARK: - 当前时间胶囊（与任务卡片同语言）

    @ViewBuilder
    private var currentDueTag: some View {
        let calendar = Calendar.current
        if isOverdue {
            tag("过期", color: .holoError)
        } else if dueDate.map({ calendar.isDateInToday($0) }) == true {
            tag(isAllDay ? "今天" : "今天 \(timeText(dueDate))", color: .holoPrimaryDark)
        } else if dueDate.map({ calendar.isDateInTomorrow($0) }) == true {
            tag(isAllDay ? "明天" : "明天 \(timeText(dueDate))", color: Color(red: 0.23, green: 0.37, blue: 0.84))
        } else {
            tag(farDueText, color: .holoTextSecondary)
        }
    }

    /// 远期任务的日期文案（M月d日 / M月d日 HH:mm）
    private var farDueText: String {
        guard let due = dueDate else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = isAllDay ? "M月d日" : "M月d日 HH:mm"
        return formatter.string(from: due)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.10)))
            .fixedSize()
    }

    private var nowText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

    private func timeText(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
