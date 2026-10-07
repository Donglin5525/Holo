//
//  TimeFilterBlock.swift
//  Holo
//
//  统计分析页顶部内联时间筛选条（2026-09-28 东林定稿）：
//  点胶囊在本条内联展开，不弹抽屉、不遮挡数据区；点档位立即生效并收起。
//  「自定义起止日期」是专注操作，收起本条并打开日历弹层。
//

import SwiftUI

struct TimeFilterBlock: View {
    @ObservedObject var state: FinanceAnalysisState
    /// 点档位/口径后收起本条
    var onSelection: () -> Void
    /// 打开自定义起止日历弹层
    var onCustomTap: () -> Void

    private static let options: [TimeRange] = [.week, .month, .quarter, .year]

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                ForEach(Self.options) { range in
                    filterChip(range)
                }
            }
            .frame(maxWidth: .infinity)

            if state.timeRange == .year && state.yearBasisSwitchAvailable {
                yearBasisRow
            }

            Button {
                onSelection()
                onCustomTap()
            } label: {
                HStack {
                    Text("自定义起止日期")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoDivider, lineWidth: 1)
        )
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.xs)
    }

    /// 档位 chip：点选即生效（setTimeRange 即时刷新数据）并收起筛选条
    private func filterChip(_ range: TimeRange) -> some View {
        let isSelected = state.timeRange == range
        return Button {
            onSelection()
            state.setTimeRange(range)
        } label: {
            Text(range.displayName)
                .font(.holoCaption)
                .fontWeight(isSelected ? .semibold : .medium)
                .foregroundColor(isSelected ? .white : .holoTextSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(isSelected ? Color.holoPrimary : Color.holoBackground)
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : Color.holoDivider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// 年档口径行（自然年/记账年，仅起始日≠1 时出现）：点选即生效并收起
    private var yearBasisRow: some View {
        HStack(spacing: HoloSpacing.sm) {
            Text("年度口径")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary)

            ForEach(FinanceYearBasis.allCases) { basis in
                let isSelected = state.yearBasis == basis
                Button {
                    onSelection()
                    state.setYearBasis(basis)
                } label: {
                    Text(basis.displayName)
                        .font(.system(size: 11))
                        .fontWeight(isSelected ? .semibold : .medium)
                        .foregroundColor(isSelected ? .white : .holoTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isSelected ? Color.holoPrimary : Color.holoBackground)
                        )
                        .overlay(
                            Capsule().stroke(isSelected ? Color.clear : Color.holoDivider, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
    }
}
