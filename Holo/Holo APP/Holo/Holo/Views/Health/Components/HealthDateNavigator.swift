//
//  HealthDateNavigator.swift
//  Holo
//
//  健康模块按天切换导航条（外层看板与详情页共用）
//

import SwiftUI

// MARK: - HealthDateNavigator

struct HealthDateNavigator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedDate: Date
    @State private var showCalendar = false

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    /// 单行日期导航：日期文案（点开日历）靠左，「今天」芯片 + 前后箭头组靠右。
    /// 三种日期状态下右侧元素位置固定，切天不产生布局跳动（10-14 版整宽胶囊曾把
    /// 「今天」挤到第二行，离开今天整页下移 48pt）。
    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            dateButton
                .layoutPriority(1)

            Spacer(minLength: HoloSpacing.sm)

            if !isToday {
                todayButton
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
            }

            arrowGroup
        }
        .frame(height: 44)
        .animation(reduceMotion ? nil : HoloAnimation.standard, value: isToday)
        .sheet(isPresented: $showCalendar) {
            HealthDatePickerSheet(selectedDate: $selectedDate)
        }
    }

    /// 日期文案：点击弹出日历，支持跨月/跨年直接跳转历史日期。
    /// 格式随 App 语言（SeedLanguage）而非写死 zh_CN（10-14 曾引入写死中文）。
    private var dateButton: some View {
        Button {
            showCalendar = true
        } label: {
            HStack(spacing: 5) {
                Text(Self.dateDisplayText(for: selectedDate))
                    .font(.system(.body, design: .default, weight: .semibold))
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.7))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
        .accessibilityIdentifier("health.datePicker")
    }

    /// 前后箭头组：胶囊底内两枚 44pt 热区按钮，位置在所有日期状态下固定
    private var arrowGroup: some View {
        HStack(spacing: 0) {
            navigationButton(systemName: "chevron.left", isDisabled: false) {
                navigateDate(-1)
            }

            navigationButton(
                systemName: "chevron.right",
                isDisabled: isToday
            ) {
                navigateDate(1)
            }
        }
        .frame(height: 36)
        .background(Color.holoToolSurface)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.holoToolBorder, lineWidth: 0.5)
        )
    }

    private func navigationButton(
        systemName: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isDisabled ? .holoToolTextSecondary.opacity(0.32) : .holoToolTextSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
        .disabled(isDisabled)
        .accessibilityLabel(Text(systemName == "chevron.left" ? "前一天" : "后一天"))
        .accessibilityIdentifier(systemName == "chevron.left" ? "health.previousDay" : "health.nextDay")
    }

    private var todayButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : HoloAnimation.standard) {
                selectedDate = Calendar.current.startOfDay(for: Date())
            }
        } label: {
            Text("今天")
                .font(.system(.caption, design: .default, weight: .semibold))
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.holoPrimary.opacity(0.1))
                .clipShape(Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
        .accessibilityIdentifier("health.returnToToday")
    }

    /// 日期文案：今天/昨天带前缀不带星期（今天 · 11月10日），更早的日期拼星期（11月8日 周日）；
    /// 跨年补年份。格式化按 App 声明语言（跟随 String(localized:) 的三语体系）。
    static func dateDisplayText(for date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return String(localized: "今天 · \(Self.appDayFormatter.string(from: date))")
        } else if calendar.isDateInYesterday(date) {
            return String(localized: "昨天 · \(Self.appDayFormatter.string(from: date))")
        }
        if !calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return Self.appCrossYearFormatter.string(from: date)
        }
        return Self.appWeekdayFormatter.string(from: date)
    }

    /// 「MMMd」按 App 语言取模板（简繁：11月10日；英文：Nov 10）
    private static let appDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Self.appLocale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// 「MMMd + 短星期」按 App 语言取模板（简繁：11月8日 周日；英文：Sun, Nov 8）
    private static let appWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Self.appLocale
        formatter.setLocalizedDateFormatFromTemplate("MMMdE")
        return formatter
    }()

    /// 跨年日期带年份（2025年12月30日 周二 / Dec 30, 2025, Tue）
    private static let appCrossYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Self.appLocale
        formatter.setLocalizedDateFormatFromTemplate("yMMMdE")
        return formatter
    }()

    private static var appLocale: Locale {
        switch SeedLanguage.current {
        case .simplifiedChinese: return Locale(identifier: "zh_CN")
        case .traditionalChinese: return Locale(identifier: "zh_TW")
        case .english: return Locale(identifier: "en_US")
        }
    }

    private func navigateDate(_ direction: Int) {
        guard let newDate = Self.steppedDate(from: selectedDate, forward: direction > 0) else { return }
        withAnimation(reduceMotion ? nil : HoloAnimation.standard) {
            selectedDate = newDate
        }
    }

    /// 按天步进的统一边界规则（箭头 / 日历 / 左右滑动切天共用）：不允许越过今天，越界返回 nil
    static func steppedDate(from date: Date, forward: Bool) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let newDate = calendar.date(byAdding: .day, value: forward ? 1 : -1, to: date),
              newDate <= today else { return nil }
        return calendar.startOfDay(for: newDate)
    }
}

// MARK: - HealthDatePickerSheet

/// 按天跳转日历弹层：点选任意历史日期立即生效并关闭，未来日期置灰不可选
private struct HealthDatePickerSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedDate: Date
    @Environment(\.dismiss) private var dismiss

    /// 点选即提交：与箭头/滑动切天共用同一条 selectedDate 写入路径，触发统一的 onChange 重载
    private var pickerSelection: Binding<Date> {
        Binding(
            get: { selectedDate },
            set: { newValue in
                withAnimation(reduceMotion ? nil : HoloAnimation.standard) {
                    selectedDate = Calendar.current.startOfDay(for: newValue)
                }
                dismiss()
            }
        )
    }

    private var selectableRange: ClosedRange<Date> {
        let lowerBound = Calendar.current.date(byAdding: .year, value: -10, to: Date())
            ?? Date(timeIntervalSinceNow: -10 * 365 * 24 * 3600)
        return lowerBound...Date()
    }

    var body: some View {
        NavigationStack {
            DatePicker(
                "",
                selection: pickerSelection,
                in: selectableRange,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HoloSpacing.md)
            .navigationTitle("选择日期")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        withAnimation(reduceMotion ? nil : HoloAnimation.standard) {
                            selectedDate = Calendar.current.startOfDay(for: Date())
                        }
                        dismiss()
                    } label: {
                        Text("今天")
                            .foregroundColor(.holoPrimary)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .holoSheetShell()
        .presentationDetents([.height(400), .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var date = Calendar.current.startOfDay(for: Date())
        var body: some View {
            HealthDateNavigator(selectedDate: $date)
                .padding()
        }
    }
    return PreviewWrapper()
}
