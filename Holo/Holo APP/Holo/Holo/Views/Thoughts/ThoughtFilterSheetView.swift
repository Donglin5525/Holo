//
//  ThoughtFilterSheetView.swift
//  Holo
//
//  观点模块 - 筛选面板
//  支持心情、日期范围等多维筛选
//

import SwiftUI

// MARK: - ThoughtFilterSheetView

/// 筛选面板视图
struct ThoughtFilterSheetView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    let onApplyFilters: (ThoughtFilters) -> Void

    /// 当前筛选条件
    @State private var selectedMood: String? = nil
    @State private var startDate: Date? = nil
    @State private var endDate: Date? = nil

    /// 展开状态
    @State private var expandedSection: FilterSection? = .mood

    // MARK: - Body

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 筛选内容
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 心情筛选
                        moodFilterSection

                        // 日期范围筛选
                        dateRangeFilterSection
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                }

                Divider()

                // 底部按钮
                bottomButtons
            }
            .background(Color.holoBackground)
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
        }
    }

    // MARK: - 心情筛选

    private var moodFilterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            HStack {
                Text("心情")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedSection = expandedSection == .mood ? nil : .mood
                    }
                } label: {
                    Image(systemName: expandedSection == .mood ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextSecondary)
                }
            }

            // 心情选项
            if expandedSection == .mood {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    ForEach(ThoughtMoodType.allCases, id: \.self) { moodType in
                        moodChip(moodType)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    private func moodChip(_ moodType: ThoughtMoodType) -> some View {
        Button {
            selectedMood = selectedMood == moodType.rawValue ? nil : moodType.rawValue
        } label: {
            VStack(spacing: 6) {
                Text(moodType.emoji)
                    .font(.system(size: 20))
                Text(moodType.displayName)
                    .font(.holoTinyLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(selectedMood == moodType.rawValue ? moodType.backgroundColor : Color.holoBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(selectedMood == moodType.rawValue ? moodType.color : Color.holoBorder, lineWidth: 1)
            )
        }
        .foregroundColor(.holoTextPrimary)
    }

    // MARK: - 日期范围筛选

    private var dateRangeFilterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            HStack {
                Text("日期范围")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                if startDate != nil || endDate != nil {
                    Button("清除") {
                        startDate = nil
                        endDate = nil
                    }
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoPrimary)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedSection = expandedSection == .dateRange ? nil : .dateRange
                    }
                } label: {
                    Image(systemName: expandedSection == .dateRange ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextSecondary)
                }
            }

            // 日期选择器
            if expandedSection == .dateRange {
                VStack(spacing: 12) {
                    // 开始日期
                    datePickerRow(title: "开始日期", date: $startDate)

                    // 结束日期
                    datePickerRow(title: "结束日期", date: $endDate)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    private func datePickerRow(title: String, date: Binding<Date?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            DatePicker(
                "",
                selection: Binding(
                    get: { date.wrappedValue ?? Date() },
                    set: { date.wrappedValue = $0 }
                ),
                displayedComponents: .date
            )
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .labelsHidden()
        }
    }

    // MARK: - 底部按钮

    private var bottomButtons: some View {
        HStack(spacing: 12) {
            // 重置按钮
            Button {
                selectedMood = nil
                startDate = nil
                endDate = nil
            } label: {
                Text("重置")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.holoBackground)
                    .cornerRadius(HoloRadius.md)
            }

            // 应用筛选按钮
            Button {
                let filters = ThoughtFilters(
                    mood: selectedMood,
                    startDate: startDate,
                    endDate: endDate
                )
                onApplyFilters(filters)
                dismiss()
            } label: {
                Text("应用")
                    .font(.holoLabel)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.holoPrimary)
                    .cornerRadius(HoloRadius.md)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
    }
}

// MARK: - FilterSection 枚举

enum FilterSection: CaseIterable {
    case mood
    case dateRange
}

// MARK: - Preview

#Preview {
    ThoughtFilterSheetView(onApplyFilters: { _ in })
}
