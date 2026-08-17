//
//  ThoughtFilterSheetView.swift
//  Holo
//
//  观点模块 - 筛选面板
//  支持日期范围等筛选
//

import SwiftUI

// MARK: - ThoughtFilterSheetView

/// 筛选面板视图
struct ThoughtFilterSheetView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    let onApplyFilters: (ThoughtFilters) -> Void

    /// 当前筛选条件
    @State private var startDate: Date? = nil
    @State private var endDate: Date? = nil
    /// P1（FR-10）：整理状态筛选
    @State private var organizationState: OrganizationStateFilter? = nil

    /// 展开状态
    @State private var expandedSection: FilterSection? = .dateRange

    // MARK: - Body

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 筛选内容
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        // 日期范围筛选
                        dateRangeFilterSection

                        // 整理状态筛选
                        organizationStateFilterSection
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

    // MARK: - 整理状态筛选（P1 FR-10）

    private var organizationStateFilterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("整理状态")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Spacer()

                if organizationState != nil {
                    Button("清除") {
                        organizationState = nil
                    }
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoPrimary)
                }
            }

            HStack(spacing: 8) {
                ForEach(OrganizationStateFilter.allCases, id: \.self) { state in
                    let isSelected = organizationState == state
                    Button {
                        organizationState = isSelected ? nil : state
                    } label: {
                        Text(state.rawValue)
                            .font(.holoCaption)
                            .foregroundColor(isSelected ? .white : .holoTextPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(isSelected ? Color.holoPrimary : Color.holoCardBackground)
                            )
                            .overlay(
                                Capsule().stroke(Color.holoBorder, lineWidth: 1)
                            )
                    }
                }
            }
        }
        .padding(16)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.lg)
    }

    // MARK: - 底部按钮

    private var bottomButtons: some View {
        HStack(spacing: 12) {
            // 重置按钮
            Button {
                startDate = nil
                endDate = nil
                organizationState = nil
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
                    mood: nil,
                    startDate: startDate,
                    endDate: endDate,
                    organizationState: organizationState
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
    case dateRange
}

// MARK: - Preview

#Preview {
    ThoughtFilterSheetView(onApplyFilters: { _ in })
}
